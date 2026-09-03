/**
 * Polls one object's HubSpot portals and applies what changed to Salesforce.
 *
 * The unit of work is a (object, portal) CURSOR ROW, not a Salesforce record --
 * inbound is driven by a HubSpot query, so there are no local rows to iterate.
 * Running with scope = 1 gives each portal its own callout, DML and heap budget,
 * so the page cap needs no cross-portal arithmetic and one failing portal cannot
 * take the others down. PortalInboundScheduler seeds any missing cursor rows
 * before launching, which is also what makes Paused__c a SOQL filter rather than
 * an in-memory check.
 *
 * CALLOUT-FIRST / DML-LAST comes free here, and it is worth saying why, because
 * it inverts the outbound story. The outbox had to be contorted to satisfy the
 * rule: what it naturally wanted was to claim rows (DML) and then call out,
 * which Apex forbids, so it abandoned row claiming altogether and leans on the
 * scheduler's overlap guard instead. Inbound's natural order already IS callout
 * then DML. The only discipline required is to keep every SOQL read before the
 * first write, which costs nothing.
 *
 * One thin subclass per object exists solely to give the scheduler a distinct
 * AsyncApexJob.ApexClass.Name to guard on -- the same reason ContactOutboxBatch
 * exists. Deliberately no Contact or Asset subclass: a missing class is a second
 * guard against enabling inbound for an object nobody has thought through.
 */
public virtual with sharing class PortalInboundBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
  protected final PortalSyncConfig.ObjectConfig cfg;

  public PortalInboundBatch(String sObjectName) {
    this.cfg = PortalSyncConfig.objectConfig(sObjectName);
    if (this.cfg == null) {
      throw new IllegalArgumentException(
        'No Portal_Sync_Object__mdt configuration for SObject: ' + sObjectName
      );
    }
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    String objName = cfg.sObjectName;
    return Database.getQueryLocator(
      'SELECT Id, Cursor_Key__c, SObject_Name__c, Portal__c, Watermark__c, Paused__c ' +
        'FROM HS_Inbound_Cursor__c ' +
        'WHERE SObject_Name__c = :objName AND Paused__c = false'
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<HS_Inbound_Cursor__c> scope
  ) {
    reportDirectionTypos();
    for (HS_Inbound_Cursor__c cursor : scope) {
      try {
        pollPortal(cursor);
      } catch (Exception e) {
        // A cursor row must never be able to abort the whole run. Its
        // watermark is left untouched, so the next run retries the same
        // window rather than skipping it.
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          'CURSOR',
          cursor.Portal__c,
          'INBOUND_CURSOR',
          'Unhandled inbound error: ' + e.getMessage()
        );
        cursor.Last_Run__c = System.now();
        cursor.Last_Status__c = PortalSyncConfig.INBOUND_FAILED;
        cursor.Last_Message__c = truncate(e.getMessage(), 255);
        Database.update(cursor, false);
        PortalSyncDeadLetter.flush();
      }
    }
  }

  public void finish(Database.BatchableContext bc) {
  }

  /**
   * Report mapping rows whose direction value is not one of the three
   * recognised strings. Each was treated as SF_to_HS, so nothing unsafe
   * happened -- but Custom Metadata Types cannot enforce a picklist, so a typo
   * that silently disables inbound for a field would otherwise be invisible.
   * Once per transaction, not once per portal.
   */
  private static Boolean typosReported = false;

  private void reportDirectionTypos() {
    if (typosReported)
      return;
    typosReported = true;
    for (
      String warning : PortalSyncConfig.directionConfigWarnings(cfg.sObjectName)
    ) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'INBOUND_CONFIG',
        null,
        'INBOUND_DIRECTION_CONFIG',
        warning
      );
    }
  }

  // ---- One (object, portal) pass ------------------------------------------

  private void pollPortal(HS_Inbound_Cursor__c cursor) {
    String portal = cursor.Portal__c;

    // --- Phase A: config + cursor (no callouts, no DML) ---
    Map<String, String> inboundMap = PortalSyncConfig.inboundFieldMapFor(
      cfg.sObjectName,
      portal
    );
    if (inboundMap.isEmpty()) {
      // No field on this object is HubSpot-owned in this portal, so there
      // is nothing to ask for. Skipped WITHOUT a callout -- per-portal
      // direction is what makes that determinable up front.
      finishCursor(
        cursor,
        null,
        PortalSyncConfig.INBOUND_OK,
        'No inbound fields configured for this portal',
        0,
        0
      );
      return;
    }

    Datetime since = (cursor.Watermark__c != null)
      ? cursor.Watermark__c
      : System.now().addDays(-cfg.inboundLookbackDays);
    since = since.addSeconds(-cfg.inboundOverlapSeconds);

    List<String> properties = new List<String>(inboundMap.keySet());
    properties.add(cfg.sfIdProperty);
    properties.add(cfg.inboundModifiedProperty);

    // --- Phase B: callouts ---
    Map<String, String> failed = new Map<String, String>();
    Map<String, Map<String, Object>> byHsId = new Map<String, Map<String, Object>>();
    String after = null;
    Integer pages = 0;
    Boolean deferred = false;

    while (true) {
      HubSpotService.SearchPage page = HubSpotService.searchModifiedSince(
        cfg,
        portal,
        cfg.inboundModifiedProperty,
        since,
        properties,
        PortalSyncConfig.BATCH_SCOPE,
        after,
        failed
      );
      if (!failed.isEmpty())
        break;
      pages++;
      for (Map<String, Object> row : page.results) {
        // Dedupe by HubSpot id: a record edited DURING paging can appear
        // on two pages, and two update shells for one Salesforce id
        // would fail the whole DML. Sorted ascending, so a later
        // occurrence is the newer one and wins.
        byHsId.put(String.valueOf(row.get('id')), row);
      }
      after = page.after;
      if (String.isBlank(after))
        break;
      if (pages >= cfg.inboundMaxPages) {
        deferred = true;
        break;
      }
    }

    if (!failed.isEmpty()) {
      for (String detail : failed.values()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          'SEARCH',
          portal,
          'INBOUND_SEARCH',
          detail
        );
      }
      // Watermark deliberately NOT advanced: records we never saw must be
      // retried, not skipped.
      finishCursor(
        cursor,
        null,
        PortalSyncConfig.INBOUND_FAILED,
        truncate(new List<String>(failed.values())[0], 255),
        byHsId.size(),
        0
      );
      return;
    }
    if (deferred) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'SEARCH',
        portal,
        'INBOUND_PAGE_CAP',
        'Stopped after ' +
          pages +
          ' pages (Inbound_Max_Pages__c); the remainder ' +
          'is picked up next run from the advanced watermark'
      );
    }
    if (byHsId.isEmpty()) {
      finishCursor(
        cursor,
        null,
        PortalSyncConfig.INBOUND_OK,
        'No changes',
        0,
        0
      );
      return;
    }

    List<Map<String, Object>> results = byHsId.values();

    // The confirmation read settles absent-vs-empty before anything is
    // blanked, and only for records that actually have a property missing.
    Map<String, Map<String, Object>> confirmed = confirmBlanks(
      portal,
      results,
      inboundMap,
      properties
    );

    // Lookups for records about to be CREATED, resolved from HubSpot's own
    // associations. Still the callout phase.
    Map<String, Map<String, Object>> resolvedLookups = resolveLookupsForCreates(
      portal,
      results
    );

    // --- Phase C: SOQL reads (still no DML) ---
    Set<Id> sfIds = new Set<Id>();
    Set<String> hsIds = new Set<String>();
    for (Map<String, Object> row : results) {
      hsIds.add(String.valueOf(row.get('id')));
      Map<String, Object> props = (Map<String, Object>) row.get('properties');
      if (props == null)
        continue;
      Object raw = props.get(cfg.sfIdProperty);
      if (raw == null)
        continue;
      String candidate = String.valueOf(raw).trim();
      try {
        sfIds.add((Id) candidate);
      } catch (Exception e) {
        /* validated in the mapper */
      }
    }

    Map<Id, SObject> existingById = queryExisting(sfIds);
    Set<String> tombstoned = queryTombstones(sfIds);
    Set<String> pendingStamps = queryPendingStamps(portal, hsIds);

    // --- Phase D: decide (pure) ---
    PortalInboundMapper.Decision decision = PortalInboundMapper.decide(
      cfg,
      portal,
      results,
      confirmed,
      existingById,
      tombstoned,
      pendingStamps,
      resolvedLookups
    );

    // --- Phase E: DML only ---
    applyDml(portal, decision);

    Datetime newWatermark = watermarkFor(cursor, decision);
    finishCursor(
      cursor,
      newWatermark,
      PortalSyncConfig.INBOUND_OK,
      deferred ? 'Deferred: page cap reached' : null,
      decision.recordsSeen,
      decision.recordsApplied()
    );
  }

  // ---- Callout helpers ----------------------------------------------------

  /**
   * Re-reads, via batch/read, only the records whose search response was
   * MISSING a requested property. HubSpot's search endpoint may omit an empty
   * property instead of returning it as null, which makes "cleared in
   * HubSpot" and "not told" indistinguishable; batch/read answers explicitly.
   * Returns hsId -> authoritative properties, empty when the pass is off or
   * unnecessary.
   */
  private Map<String, Map<String, Object>> confirmBlanks(
    String portal,
    List<Map<String, Object>> results,
    Map<String, String> inboundMap,
    List<String> properties
  ) {
    Map<String, Map<String, Object>> confirmed = new Map<String, Map<String, Object>>();
    if (cfg.inboundConfirmBlanks != true)
      return confirmed;

    List<String> needsConfirming = new List<String>();
    for (Map<String, Object> row : results) {
      Map<String, Object> props = (Map<String, Object>) row.get('properties');
      if (props == null) {
        needsConfirming.add(String.valueOf(row.get('id')));
        continue;
      }
      for (String hsProperty : inboundMap.keySet()) {
        if (!props.containsKey(hsProperty)) {
          needsConfirming.add(String.valueOf(row.get('id')));
          break;
        }
      }
    }
    if (needsConfirming.isEmpty())
      return confirmed;

    Map<String, String> failed = new Map<String, String>();
    confirmed = HubSpotService.batchReadProperties(
      cfg,
      portal,
      needsConfirming,
      properties,
      failed
    );
    for (String detail : failed.values()) {
      // A failed confirmation must not become a clear. Returning nothing
      // for those ids leaves the mapper reading the search response, where
      // the property is absent -- and absent always means SKIP.
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'CONFIRM',
        portal,
        'INBOUND_CONFIRM',
        detail
      );
    }
    return confirmed;
  }

  /**
   * For records about to be created, work out their Salesforce lookup values
   * from HubSpot's own associations: read the HubSpot record's linked records,
   * then read the sf-id property off those, giving a Salesforce id to put in
   * the lookup field.
   *
   * Without this a HubSpot-originated deal arrives with a null AccountId, and
   * the very next outbox run computes "desired associations = none" and
   * ARCHIVES the deal's real company and contact links in HubSpot -- stripping
   * the record a user just created. PortalAssociationRouter now refuses to act
   * on that ambiguity, so this is the other half: give the record its real
   * parent rather than merely declining to destroy anything.
   *
   * Lookup-source associations only. A Junction source (e.g.
   * OpportunityContactRole) would need child rows inserted rather than a field
   * set, which is a different shape of work and out of scope here -- such
   * associations should carry Suppress_Removals__c while inbound creates are on.
   *
   * Returns hsId -> (SF lookup field -> SF id). Anything that cannot be
   * resolved is simply absent; the create still proceeds unless the lookup is
   * genuinely required, in which case the create pre-flight refuses it by name.
   */
  private Map<String, Map<String, Object>> resolveLookupsForCreates(
    String portal,
    List<Map<String, Object>> results
  ) {
    Map<String, Map<String, Object>> byHsId = new Map<String, Map<String, Object>>();
    if (cfg.inboundCreateUnmatched != true)
      return byHsId;

    List<String> candidates = new List<String>();
    for (Map<String, Object> row : results) {
      Map<String, Object> props = (Map<String, Object>) row.get('properties');
      String sfId = (props == null)
        ? null
        : trimToNull(props.get(cfg.sfIdProperty));
      if (sfId == null)
        candidates.add(String.valueOf(row.get('id')));
    }
    if (candidates.isEmpty())
      return byHsId;

    for (
      PortalSyncConfig.AssociationConfig a : PortalSyncConfig.associationsFrom(
        cfg.sObjectName
      )
    ) {
      if (a.isJunction() || String.isBlank(a.relationshipField))
        continue;
      if (!a.syncsTo(portal))
        continue;
      Integer typeId = a.typeIdFor(portal);
      if (typeId == null)
        continue; // never guess a type id
      PortalSyncConfig.ObjectConfig toCfg = PortalSyncConfig.objectConfig(
        a.toObject
      );
      if (toCfg == null)
        continue;

      Map<String, String> readFailed = new Map<String, String>();
      Map<String, Set<String>> linkedByFrom = HubSpotService.batchReadAssociations(
        a.fromHubSpotPath,
        a.toHubSpotPath,
        portal,
        candidates,
        a.associationCategory,
        typeId,
        readFailed
      );

      Set<String> toHsIds = new Set<String>();
      for (Set<String> linked : linkedByFrom.values())
        toHsIds.addAll(linked);
      if (toHsIds.isEmpty())
        continue;

      Map<String, String> propFailed = new Map<String, String>();
      Map<String, Map<String, Object>> toProps = HubSpotService.batchReadProperties(
        toCfg,
        portal,
        new List<String>(toHsIds),
        new List<String>{ toCfg.sfIdProperty },
        propFailed
      );

      for (String fromHs : linkedByFrom.keySet()) {
        for (String toHs : linkedByFrom.get(fromHs)) {
          Map<String, Object> p = toProps.get(toHs);
          String relatedSfId = (p == null)
            ? null
            : trimToNull(p.get(toCfg.sfIdProperty));
          if (relatedSfId == null)
            continue;
          if (!byHsId.containsKey(fromHs)) {
            byHsId.put(fromHs, new Map<String, Object>());
          }
          // A lookup holds one value; HubSpot may report several. Take
          // the first that resolves rather than inventing a rule for
          // which of several parents is the "real" one.
          if (!byHsId.get(fromHs).containsKey(a.relationshipField)) {
            byHsId.get(fromHs).put(a.relationshipField, relatedSfId);
          }
          break;
        }
      }
    }
    return byHsId;
  }

  private static String trimToNull(Object raw) {
    if (raw == null)
      return null;
    String s = String.valueOf(raw).trim();
    return String.isBlank(s) ? null : s;
  }

  // ---- SOQL helpers -------------------------------------------------------

  private Map<Id, SObject> queryExisting(Set<Id> sfIds) {
    if (sfIds.isEmpty())
      return new Map<Id, SObject>();
    Set<String> fields = new Set<String>{
      'Id',
      'CreatedDate',
      'LastModifiedDate',
      cfg.portalField
    };
    fields.addAll(PortalSyncConfig.inboundSfFields(cfg.sObjectName));
    if (String.isNotBlank(cfg.contentChangedField))
      fields.add(cfg.contentChangedField);
    return new Map<Id, SObject>(
      Database.query(
        'SELECT ' +
          String.join(new List<String>(fields), ', ') +
          ' FROM ' +
          cfg.sObjectName +
          ' WHERE Id IN :sfIds'
      )
    );
  }

  private Set<String> queryTombstones(Set<Id> sfIds) {
    Set<String> out = new Set<String>();
    if (sfIds.isEmpty())
      return out;
    Set<String> asText = new Set<String>();
    for (Id i : sfIds)
      asText.add(String.valueOf(i));
    String objName = cfg.sObjectName;
    for (HS_Sync_Tombstone__c t : [
      SELECT Record_Id__c
      FROM HS_Sync_Tombstone__c
      WHERE SObject_Name__c = :objName AND Record_Id__c IN :asText
    ]) {
      out.add(t.Record_Id__c);
    }
    return out;
  }

  private Set<String> queryPendingStamps(String portal, Set<String> hsIds) {
    Set<String> out = new Set<String>();
    if (hsIds.isEmpty())
      return out;
    String objName = cfg.sObjectName;
    for (HS_Inbound_Stamp__c s : [
      SELECT HubSpot_Id__c
      FROM HS_Inbound_Stamp__c
      WHERE
        SObject_Name__c = :objName
        AND Portal__c = :portal
        AND HubSpot_Id__c IN :hsIds
    ]) {
      out.add(s.HubSpot_Id__c);
    }
    return out;
  }

  // ---- DML ----------------------------------------------------------------

  /** Partial-success on purpose: one validation rule on one record must not
   *  lose a whole page of good writes, nor roll back the cursor advance and
   *  leave the run replaying the same window forever. */
  private void applyDml(String portal, PortalInboundMapper.Decision decision) {
    if (!decision.updates.isEmpty()) {
      Database.SaveResult[] results = Database.update(decision.updates, false);
      for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess())
          continue;
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          String.valueOf(decision.updates[i].Id),
          portal,
          'INBOUND_DML',
          errorsOf(results[i].getErrors())
        );
        // Hold the watermark below this record so the next run retries
        // it, instead of advancing past a write that never landed.
        decision.noteFailed(decision.updateModifieds[i]);
      }
    }

    if (!decision.creates.isEmpty()) {
      Database.SaveResult[] results = Database.insert(decision.creates, false);
      List<HS_Inbound_Stamp__c> stamps = new List<HS_Inbound_Stamp__c>();
      for (Integer i = 0; i < results.size(); i++) {
        String hsId = decision.createHsIds[i];
        if (!results[i].isSuccess()) {
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            'CREATE',
            portal,
            'INBOUND_CREATE',
            'HubSpot ' + hsId + ': ' + errorsOf(results[i].getErrors())
          );
          decision.noteFailed(decision.createModifieds[i]);
          continue;
        }
        // The created record is held in Awaiting_Writeback until this
        // stamp row drains, so it cannot be pushed back to HubSpot as a
        // duplicate before its id has been written to the original.
        stamps.add(
          new HS_Inbound_Stamp__c(
            Record_Id__c = String.valueOf(results[i].getId()),
            HubSpot_Id__c = hsId,
            Portal__c = portal,
            SObject_Name__c = cfg.sObjectName,
            Status__c = PortalSyncConfig.STATUS_PENDING,
            Retry_Count__c = 0
          )
        );
      }
      if (!stamps.isEmpty()) {
        Database.SaveResult[] stampResults = Database.insert(stamps, false);
        for (Integer i = 0; i < stampResults.size(); i++) {
          if (stampResults[i].isSuccess())
            continue;
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            stamps[i].Record_Id__c,
            portal,
            'INBOUND_STAMP',
            'Could not queue the sf-id write-back for HubSpot ' +
              stamps[i].HubSpot_Id__c +
              ': ' +
              errorsOf(stampResults[i].getErrors())
          );
        }
      }
    }
  }

  /**
   * The watermark to store.
   *
   * A clean pass advances to the newest record processed. A pass with per-record
   * failures cuts to just BELOW the oldest failure, so the failed record is
   * seen again next run instead of being stepped over. Valid because results
   * are sorted ascending. Never moves backwards -- a rewind would replay
   * indefinitely.
   */
  private Datetime watermarkFor(
    HS_Inbound_Cursor__c cursor,
    PortalInboundMapper.Decision decision
  ) {
    Datetime candidate = (decision.minFailedModified != null)
      ? decision.minFailedModified.addSeconds(-1)
      : decision.maxProcessedModified;
    if (candidate == null)
      return cursor.Watermark__c;
    if (cursor.Watermark__c != null && candidate < cursor.Watermark__c)
      return cursor.Watermark__c;
    return candidate;
  }

  private void finishCursor(
    HS_Inbound_Cursor__c cursor,
    Datetime watermark,
    String status,
    String message,
    Integer seen,
    Integer applied
  ) {
    if (watermark != null)
      cursor.Watermark__c = watermark;
    cursor.Last_Run__c = System.now();
    cursor.Last_Status__c = status;
    cursor.Last_Message__c = truncate(message, 255);
    cursor.Records_Seen__c = seen;
    cursor.Records_Applied__c = applied;
    Database.update(cursor, false);
    PortalSyncDeadLetter.flush();
  }

  private static String errorsOf(List<Database.Error> errors) {
    List<String> parts = new List<String>();
    for (Database.Error e : errors) {
      parts.add(
        e.getStatusCode() +
          ': ' +
          e.getMessage() +
          (e.getFields().isEmpty()
            ? ''
            : ' [' + String.join(e.getFields(), ', ') + ']')
      );
    }
    return String.join(parts, '; ');
  }

  private static String truncate(String value, Integer max) {
    if (value == null)
      return null;
    return (value.length() > max) ? value.substring(0, max) : value;
  }
}
