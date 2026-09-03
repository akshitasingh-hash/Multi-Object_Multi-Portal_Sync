/**
 * The inbound decide phase: turns HubSpot search results into Salesforce DML,
 * and decides what NOT to write.
 *
 * Deliberately free of SOQL, DML and callouts. Everything it needs is passed in,
 * so the whole decision matrix is unit-testable synchronously -- which matters
 * because batch execution resets statics and drops any seeded config cache, so
 * logic living inside a batch cannot be tested against seeded metadata.
 *
 * Three rules carry most of the weight:
 *
 *  1. VALUE EQUALITY IS THE LOOP TERMINATOR. A field is written only when the
 *     converted incoming value actually differs from the current Salesforce
 *     value; a record with no differing field is not added to the DML list at
 *     all. That is what makes the engine's own outbound echo harmless: the poll
 *     proposes the value Salesforce already has, finds it, and does nothing --
 *     no DML, so no Pending stamp, so no push, so no new HubSpot timestamp.
 *     Comparison is TYPED, not string-based: String.valueOf(1000.50) is
 *     '1000.50' while HubSpot returns '1000.5', and comparing those as text
 *     would rewrite the field on every single poll, forever.
 *
 *  2. THREE STATES, NOT TWO. Each field resolves to APPLY / CLEAR / SKIP. A
 *     null Object cannot express this -- it conflates "clear it" with "no
 *     opinion" -- and conflating them is how an inbound sync silently erases a
 *     CRM. A property ABSENT from the response is unknown (SKIP); a property
 *     PRESENT but empty is a deliberate clear (CLEAR).
 *
 *  3. AMBIGUITY IS REFUSED, NEVER GUESSED. An untranslatable value, an
 *     ambiguous reverse mapping, an unwritable field, a clear on a required
 *     field: each omits that one field and dead-letters, rather than writing a
 *     guess. Same principle as the association router skipping a portal with no
 *     type id -- writing the wrong value is worse than writing nothing, because
 *     it is silent.
 */
public with sharing class PortalInboundMapper {
  /** What one inbound pass decided to do. */
  public class Decision {
    public List<SObject> updates = new List<SObject>();
    /** Records to insert. Parallel to createHsIds -- index i of one
     *  corresponds to index i of the other, so the stamp rows can be built
     *  after the insert assigns ids. */
    public List<SObject> creates = new List<SObject>();
    public List<String> createHsIds = new List<String>();

    /** The HubSpot modified-date behind each queued write, parallel to the
     *  two lists above. The caller needs these so a per-record DML failure
     *  can hold the watermark BELOW that record rather than stepping over
     *  it -- otherwise a record that fails a validation rule is never seen
     *  again unless it happens to change in HubSpot a second time. */
    public List<Datetime> updateModifieds = new List<Datetime>();
    public List<Datetime> createModifieds = new List<Datetime>();

    /** Newest HubSpot modified-date fully processed, and the oldest one that
     *  failed. The caller advances its watermark to maxProcessed on a clean
     *  pass, or to just below minFailed otherwise, so a failure is retried
     *  rather than skipped. */
    public Datetime maxProcessedModified;
    public Datetime minFailedModified;

    public Integer recordsSeen = 0;

    /** Records this pass will actually write. Compare against recordsSeen:
     *  a high Seen with a near-zero Applied is the healthy steady state. */
    public Integer recordsApplied() {
      return updates.size() + creates.size();
    }

    void noteProcessed(Datetime modified) {
      if (modified == null)
        return;
      if (maxProcessedModified == null || modified > maxProcessedModified) {
        maxProcessedModified = modified;
      }
    }

    /** Public so the batch can report a DML failure discovered after the
     *  decide phase, which is the only place per-record failures surface. */
    public void noteFailed(Datetime modified) {
      if (modified == null)
        return;
      if (minFailedModified == null || modified < minFailedModified) {
        minFailedModified = modified;
      }
    }
  }

  /** One field's outcome. `kind` is APPLY, CLEAR or SKIP. */
  private enum FieldAction {
    APPLY,
    CLEAR,
    SKIP
  }

  private class FieldDecision {
    FieldAction action;
    Object value; // only meaningful for APPLY
    FieldDecision(FieldAction action, Object value) {
      this.action = action;
      this.value = value;
    }
  }

  // ---- Entry point --------------------------------------------------------

  /**
   * @param results          raw search results (each with 'id' and 'properties')
   * @param confirmedProps   hsId -> authoritative properties from batch/read,
   *                         used to settle absent-vs-empty. Empty map when the
   *                         confirmation pass did not run.
   * @param existingById     already-queried Salesforce records, by id
   * @param tombstonedSfIds  sf-ids with a pending delete tombstone
   * @param pendingStampHsIds HubSpot ids whose sf-id write-back has not landed
   *                          yet -- skipped, or a replay would create a second
   *                          Salesforce record for the same HubSpot record
   * @param resolvedLookups  hsId -> (SF lookup field -> SF id), resolved from
   *                         HubSpot's associations, applied to CREATES only so
   *                         a HubSpot-originated record is not born orphaned
   */
  public static Decision decide(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    List<Map<String, Object>> results,
    Map<String, Map<String, Object>> confirmedProps,
    Map<Id, SObject> existingById,
    Set<String> tombstonedSfIds,
    Set<String> pendingStampHsIds,
    Map<String, Map<String, Object>> resolvedLookups
  ) {
    Decision d = new Decision();
    Map<String, String> inboundMap = PortalSyncConfig.inboundFieldMapFor(
      cfg.sObjectName,
      portal
    );
    if (results == null || results.isEmpty() || inboundMap.isEmpty())
      return d;

    Set<String> bidirectional = PortalSyncConfig.bidirectionalSfFields(
      cfg.sObjectName,
      portal
    );
    Id recordTypeId = resolveRecordType(cfg);

    // The sf-id property is free text in HubSpot, so two records can claim
    // the same Salesforce id. Two update shells for one id fail the entire
    // DML, so the second claimant is refused rather than allowed to poison
    // the batch.
    Set<Id> claimedSfIds = new Set<Id>();

    for (Map<String, Object> row : results) {
      d.recordsSeen++;
      String hsId = String.valueOf(row.get('id'));
      Map<String, Object> props = (Map<String, Object>) row.get('properties');
      if (props == null)
        props = new Map<String, Object>();

      // The confirmation read is authoritative where it ran: it returns
      // every requested property explicitly, so it can distinguish an
      // empty value from one search merely omitted.
      Map<String, Object> confirmed = (confirmedProps != null)
        ? confirmedProps.get(hsId)
        : null;

      Datetime hsModified = parseDatetime(
        props.get(cfg.inboundModifiedProperty)
      );
      String rawSfId = trimToNull(props.get(cfg.sfIdProperty));

      // --- Identity: match, create, or refuse -------------------------
      if (rawSfId == null) {
        if (pendingStampHsIds != null && pendingStampHsIds.contains(hsId)) {
          // The sf-id write-back for this HubSpot record is still
          // queued. Its Salesforce record already exists; creating
          // another would duplicate it.
          d.noteProcessed(hsModified);
          continue;
        }
        if (cfg.inboundCreateUnmatched != true) {
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            'UNMATCHED',
            portal,
            'INBOUND_UNMATCHED',
            'HubSpot ' +
              hsId +
              ' has no ' +
              cfg.sfIdProperty +
              ' and Inbound_Create_Unmatched__c is off -- not created'
          );
          d.noteProcessed(hsModified);
          continue;
        }
        Map<String, Object> lookups = (resolvedLookups != null)
          ? resolvedLookups.get(hsId)
          : null;
        SObject created = buildCreate(
          cfg,
          portal,
          hsId,
          props,
          confirmed,
          inboundMap,
          recordTypeId,
          lookups
        );
        if (created != null) {
          d.creates.add(created);
          d.createHsIds.add(hsId);
          d.createModifieds.add(hsModified);
        }
        d.noteProcessed(hsModified);
        continue;
      }

      if (!isIdShaped(rawSfId, cfg.sObjectName)) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          'SF_ID',
          portal,
          'INBOUND_SF_ID_MISMATCH',
          'HubSpot ' +
            hsId +
            ' carries ' +
            cfg.sfIdProperty +
            ' = "' +
            rawSfId +
            '", which is not a valid ' +
            cfg.sObjectName +
            ' id -- skipped'
        );
        d.noteProcessed(hsModified);
        continue;
      }

      Id sfId = (Id) rawSfId;
      if (claimedSfIds.contains(sfId)) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          portal,
          'INBOUND_SF_ID_MISMATCH',
          'HubSpot ' +
            hsId +
            ' claims ' +
            cfg.sfIdProperty +
            ' = ' +
            sfId +
            ', already claimed by another record in this portal -- skipped. ' +
            'The sf-id property should be unique in HubSpot.'
        );
        d.noteProcessed(hsModified);
        continue;
      }
      claimedSfIds.add(sfId);

      SObject existing = (existingById != null) ? existingById.get(sfId) : null;

      if (existing == null) {
        // The sf-id property is populated but the Salesforce record is
        // gone. This is a DELETED record, never a new one. Recreating it
        // is what would break delete-termination -- the property the
        // whole engine rests on -- so it is refused unconditionally,
        // with no time window to get wrong.
        Boolean tombstoned =
          tombstonedSfIds != null && tombstonedSfIds.contains(sfId);
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          portal,
          tombstoned ? 'INBOUND_TOMBSTONED' : 'INBOUND_ORPHAN',
          tombstoned
            ? 'Deleted in Salesforce, archive from HubSpot still pending -- HubSpot ' +
              hsId +
              ' not recreated'
            : 'Deleted in Salesforce with no tombstone; HubSpot ' +
              hsId +
              ' still carries its id and was never archived -- not recreated'
        );
        d.noteProcessed(hsModified);
        continue;
      }

      // --- Portal isolation -------------------------------------------
      // Salesforce owns portal membership. A poll from a portal the record
      // does not belong to must not silently add it.
      Set<String> selected = PortalSyncConfig.selectedPortals(existing, cfg);
      if (!selected.contains(portal)) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          portal,
          'INBOUND_PORTAL_MISMATCH',
          'Polled from ' +
            portal +
            ' but the record belongs to [' +
            String.join(new List<String>(selected), ', ') +
            '] -- not applied'
        );
        d.noteProcessed(hsModified);
        continue;
      }

      // --- Conflict ---------------------------------------------------
      Boolean hubSpotWins = hubSpotIsNewer(cfg, existing, hsModified);

      SObject updateShell = buildUpdate(
        cfg,
        portal,
        existing,
        hsId,
        props,
        confirmed,
        inboundMap,
        bidirectional,
        hubSpotWins
      );
      if (updateShell != null) {
        d.updates.add(updateShell);
        d.updateModifieds.add(hsModified);
      }
      d.noteProcessed(hsModified);
    }
    return d;
  }

  // ---- Update path --------------------------------------------------------

  /** An update shell carrying only the fields that actually change, or null
   *  when nothing does (rule 1 -- no DML at all in that case). */
  private static SObject buildUpdate(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    SObject existing,
    String hsId,
    Map<String, Object> props,
    Map<String, Object> confirmed,
    Map<String, String> inboundMap,
    Set<String> bidirectional,
    Boolean hubSpotWins
  ) {
    Map<String, Object> changes = new Map<String, Object>();

    for (String hsProperty : inboundMap.keySet()) {
      String sfField = inboundMap.get(hsProperty);

      // A Bidirectional field is HubSpot's to write only when HubSpot's
      // copy is genuinely newer. An HS_to_SF field is HubSpot-owned by
      // declaration, so it is written regardless -- there is nothing to
      // arbitrate.
      if (bidirectional.contains(sfField) && !hubSpotWins)
        continue;

      FieldDecision fd = decideField(
        cfg,
        portal,
        sfField,
        hsProperty,
        props,
        confirmed,
        existing.Id
      );
      if (fd.action == FieldAction.SKIP)
        continue;

      Object current = safeGet(existing, sfField);
      if (fd.action == FieldAction.CLEAR) {
        if (current != null)
          changes.put(sfField, null);
        continue;
      }
      if (!valuesEqual(current, fd.value)) {
        changes.put(sfField, fd.value);
      }
    }

    if (changes.isEmpty())
      return null;

    SObject shell = Schema.getGlobalDescribe()
      .get(cfg.sObjectName)
      .newSObject(existing.Id);
    for (String f : changes.keySet()) {
      shell.put(f, changes.get(f));
    }
    return shell;
  }

  // ---- Create path --------------------------------------------------------

  /** A new record, or null when it cannot be built completely. Portal__c is
   *  stamped from the ORIGINATING portal, and only here -- inbound never
   *  changes an existing record's portal membership. */
  private static SObject buildCreate(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    String hsId,
    Map<String, Object> props,
    Map<String, Object> confirmed,
    Map<String, String> inboundMap,
    Id recordTypeId,
    Map<String, Object> resolvedLookups
  ) {
    SObject record = Schema.getGlobalDescribe()
      .get(cfg.sObjectName)
      .newSObject();
    Set<String> supplied = new Set<String>();

    // Lookups resolved from HubSpot's associations, applied first so a
    // mapped field can still override one if an admin has configured both.
    if (resolvedLookups != null) {
      for (String lookupField : resolvedLookups.keySet()) {
        Schema.DescribeFieldResult dfr = fieldDescribe(
          cfg.sObjectName,
          lookupField
        );
        if (dfr == null || !dfr.isCreateable())
          continue;
        try {
          record.put(
            lookupField,
            (Id) String.valueOf(resolvedLookups.get(lookupField))
          );
          supplied.add(lookupField.toLowerCase());
        } catch (Exception e) {
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            'CREATE',
            portal,
            'INBOUND_TYPE',
            'Could not set ' +
              lookupField +
              ' from the HubSpot association for ' +
              hsId +
              ': ' +
              e.getMessage()
          );
        }
      }
    }

    for (String hsProperty : inboundMap.keySet()) {
      String sfField = inboundMap.get(hsProperty);
      FieldDecision fd = decideField(
        cfg,
        portal,
        sfField,
        hsProperty,
        props,
        confirmed,
        null
      );
      if (fd.action != FieldAction.APPLY)
        continue; // nothing to clear on a new record
      Schema.DescribeFieldResult dfr = fieldDescribe(cfg.sObjectName, sfField);
      if (dfr == null || !dfr.isCreateable()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          'INBOUND_CONFIG',
          portal,
          'INBOUND_NOT_WRITEABLE',
          sfField +
            ' is not createable -- omitted from the record created from HubSpot ' +
            hsId
        );
        continue;
      }
      record.put(sfField, fd.value);
      supplied.add(sfField.toLowerCase());
    }

    record.put(cfg.portalField, portal);
    if (recordTypeId != null)
      record.put('RecordTypeId', recordTypeId);

    // Hold the record out of the outbox until its Salesforce id has been
    // written back to HubSpot. See PortalSyncConfig.STATUS_AWAITING_WRITEBACK.
    record.put(cfg.statusField, PortalSyncConfig.STATUS_AWAITING_WRITEBACK);
    record.put(cfg.retryCountField, 0);

    // Pre-flight the required fields rather than letting DML fail: the error
    // then names the field an admin has to map, instead of being an opaque
    // REQUIRED_FIELD_MISSING against a record that does not exist yet.
    List<String> missing = missingRequiredFields(cfg.sObjectName, supplied);
    if (!missing.isEmpty()) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'CREATE',
        portal,
        'INBOUND_CREATE_INCOMPLETE',
        'HubSpot ' +
          hsId +
          ' cannot create a ' +
          cfg.sObjectName +
          ': no mapping supplies required field(s) ' +
          String.join(missing, ', ')
      );
      return null;
    }
    return record;
  }

  /** Required, createable fields no mapping supplies. Owner and record type are
   *  excluded: both come from config or from the org default, not from HubSpot. */
  private static List<String> missingRequiredFields(
    String sObjectName,
    Set<String> supplied
  ) {
    List<String> missing = new List<String>();
    Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectName);
    if (sot == null)
      return missing;
    for (Schema.SObjectField f : sot.getDescribe().fields.getMap().values()) {
      Schema.DescribeFieldResult dfr = f.getDescribe();
      String name = dfr.getName();
      if (name == 'OwnerId' || name == 'RecordTypeId')
        continue;
      if (!dfr.isCreateable())
        continue;
      if (dfr.isNillable() || dfr.isDefaultedOnCreate())
        continue;
      if (dfr.isAutoNumber() || dfr.isCalculated())
        continue;
      if (!supplied.contains(name.toLowerCase()))
        missing.add(name);
    }
    return missing;
  }

  /** RecordTypeId for inbound-created records, from the configured
   *  DeveloperName. Null means "let Salesforce choose the user's default". */
  private static Id resolveRecordType(PortalSyncConfig.ObjectConfig cfg) {
    if (String.isBlank(cfg.inboundRecordType))
      return null;
    Map<String, Id> byName = recordTypeIdsByDeveloperName(cfg.sObjectName);
    return byName.get(cfg.inboundRecordType.toLowerCase());
  }

  // ---- Per-field decision -------------------------------------------------

  private static FieldDecision decideField(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    String sfField,
    String hsProperty,
    Map<String, Object> props,
    Map<String, Object> confirmed,
    Id sfIdForLog
  ) {
    String logId = (sfIdForLog != null)
      ? String.valueOf(sfIdForLog)
      : 'INBOUND_CONFIG';

    // Writeability first: a field we could never write is a config error, and
    // reporting it per record would bury it.
    if (sfField.contains('.')) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'INBOUND_CONFIG',
        portal,
        'INBOUND_NOT_WRITEABLE',
        sfField + ' is a cross-object path and cannot be written inbound'
      );
      return skip();
    }
    Schema.DescribeFieldResult dfr = fieldDescribe(cfg.sObjectName, sfField);
    if (dfr == null) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'INBOUND_CONFIG',
        portal,
        'INBOUND_NOT_WRITEABLE',
        sfField + ' does not exist on ' + cfg.sObjectName
      );
      return skip();
    }
    if (!dfr.isUpdateable() && !'RecordTypeId'.equalsIgnoreCase(sfField)) {
      PortalSyncDeadLetter.log(
        cfg.sObjectName,
        'INBOUND_CONFIG',
        portal,
        'INBOUND_NOT_WRITEABLE',
        sfField +
        ' is not updateable (formula, roll-up, auto-number or system field)'
      );
      return skip();
    }

    // --- Absent vs present-but-empty --------------------------------------
    // This is the distinction the whole null design rests on, so it is read
    // structurally from the parsed JSON rather than inferred from the value.
    Boolean useConfirmed = (confirmed != null);
    Map<String, Object> source = useConfirmed ? confirmed : props;
    if (!source.containsKey(hsProperty)) {
      // Not in the response at all => we were not told anything about it.
      // Never a clear.
      return skip();
    }
    String raw = trimToNull(source.get(hsProperty));
    if (raw == null) {
      // Present and empty => a deliberate clear, subject to consent and to
      // whether the field can legally hold null at all.
      if (!PortalSyncConfig.inboundClears(cfg.sObjectName, sfField))
        return skip();
      if (!dfr.isNillable()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          logId,
          portal,
          'INBOUND_NULL_REFUSED',
          'HubSpot ' +
            hsProperty +
            ' is empty but ' +
            sfField +
            ' is required in Salesforce -- not cleared'
        );
        return skip();
      }
      return new FieldDecision(FieldAction.CLEAR, null);
    }

    // --- Value translation ------------------------------------------------
    String translated = raw;
    if (PortalSyncConfig.hasReverseValueMap(cfg.sObjectName, sfField)) {
      if (
        PortalSyncConfig.isReverseAmbiguous(
          cfg.sObjectName,
          sfField,
          portal,
          raw
        )
      ) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          logId,
          portal,
          'INBOUND_VALUE_MAP_AMBIGUOUS',
          'Two Salesforce values both map to ' +
            hsProperty +
            ' = "' +
            raw +
            '" in ' +
            portal +
            ' and none is marked Inbound Preferred -- ' +
            sfField +
            ' omitted'
        );
        return skip();
      }
      translated = PortalSyncConfig.reverseTranslateValue(
        cfg.sObjectName,
        sfField,
        portal,
        raw
      );
      if (translated == null) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          logId,
          portal,
          'INBOUND_VALUE_MAP',
          'No Portal_Sync_Value_Map row reverses ' +
            hsProperty +
            ' = "' +
            raw +
            '" in ' +
            portal +
            ' -- ' +
            sfField +
            ' omitted rather than written raw'
        );
        return skip();
      }
    }

    // --- Type conversion --------------------------------------------------
    return convert(
      cfg,
      portal,
      sfField,
      hsProperty,
      dfr,
      translated,
      raw,
      logId
    );
  }

  private static FieldDecision skip() {
    return new FieldDecision(FieldAction.SKIP, null);
  }

  // ---- Conversion (the inverse of HubSpotService.normalize) ---------------

  /**
   * String -> typed Salesforce value.
   *
   * Asymmetric with the outbound side on purpose: outbound reads the RUNTIME
   * TYPE of the value it already holds, whereas inbound has only a String from
   * JSON and must consult the field describe.
   */
  private static FieldDecision convert(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    String sfField,
    String hsProperty,
    Schema.DescribeFieldResult dfr,
    String value,
    String rawForLog,
    String logId
  ) {
    Schema.DisplayType t = dfr.getType();
    try {
      // RecordTypeId is the mirror of normalize()'s special case: the value
      // map yields a DeveloperName, which the describe turns into an id. A
      // DeveloperName rather than an id so the config stays portable
      // between sandbox and production.
      if ('RecordTypeId'.equalsIgnoreCase(sfField)) {
        Id rtId = recordTypeIdsByDeveloperName(cfg.sObjectName)
          .get(value.toLowerCase());
        if (rtId == null) {
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            logId,
            portal,
            'INBOUND_RECORD_TYPE',
            'Record type "' +
              value +
              '" is unknown, inactive or unavailable on ' +
              cfg.sObjectName +
              ' -- omitted'
          );
          return skip();
        }
        return new FieldDecision(FieldAction.APPLY, rtId);
      }

      if (t == Schema.DisplayType.BOOLEAN) {
        String v = value.toLowerCase();
        if (v == 'true' || v == '1')
          return new FieldDecision(FieldAction.APPLY, true);
        if (v == 'false' || v == '0')
          return new FieldDecision(FieldAction.APPLY, false);
        return refuseType(
          cfg,
          portal,
          sfField,
          hsProperty,
          rawForLog,
          logId,
          'not a boolean'
        );
      }

      if (
        t == Schema.DisplayType.DOUBLE ||
        t == Schema.DisplayType.CURRENCY ||
        t == Schema.DisplayType.PERCENT
      ) {
        return new FieldDecision(FieldAction.APPLY, Decimal.valueOf(value));
      }
      if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
        // HubSpot may render a whole number as "5.0"; round rather than
        // reject, but refuse anything with a real fractional part.
        Decimal dec = Decimal.valueOf(value);
        if (dec.scale() > 0 && dec != dec.setScale(0)) {
          return refuseType(
            cfg,
            portal,
            sfField,
            hsProperty,
            rawForLog,
            logId,
            'has a fractional part but ' + sfField + ' is a whole number'
          );
        }
        return new FieldDecision(FieldAction.APPLY, dec.longValue());
      }

      if (t == Schema.DisplayType.DATE) {
        return new FieldDecision(FieldAction.APPLY, parseDate(value));
      }
      if (t == Schema.DisplayType.DATETIME) {
        return new FieldDecision(FieldAction.APPLY, parseDatetime(value));
      }

      if (t == Schema.DisplayType.PICKLIST) {
        // A picklist rejects any value that is not one of its options, so
        // an unrecognised value must be refused HERE. Otherwise the DML
        // fails per record -- and for a HubSpot property whose value is a
        // portal-scoped internal id (dealstage being the obvious case),
        // that would fail on every poll, forever. The fix is a
        // Portal_Sync_Value_Map row, so the message says so.
        if (!isValidPicklistValue(dfr, value)) {
          PortalSyncDeadLetter.log(
            cfg.sObjectName,
            logId,
            portal,
            'INBOUND_VALUE_MAP',
            hsProperty +
              ' = "' +
              rawForLog +
              '" is not a valid ' +
              sfField +
              ' picklist value' +
              (value == rawForLog ? '' : ' (translated to "' + value + '")') +
              '. Add a Portal_Sync_Value_Map row for this portal -- ' +
              sfField +
              ' omitted rather than written raw.'
          );
          return skip();
        }
        return new FieldDecision(FieldAction.APPLY, value);
      }

      if (
        t == Schema.DisplayType.STRING ||
        t == Schema.DisplayType.TEXTAREA ||
        t == Schema.DisplayType.EMAIL ||
        t == Schema.DisplayType.PHONE ||
        t == Schema.DisplayType.URL
      ) {
        Integer max = dfr.getLength();
        if (max != null && max > 0 && value.length() > max) {
          // Refused, not truncated. Silent truncation corrupts data and
          // is invisible; a dead letter is loud and fixable.
          return refuseType(
            cfg,
            portal,
            sfField,
            hsProperty,
            rawForLog,
            logId,
            'is ' +
              value.length() +
              ' characters but ' +
              sfField +
              ' holds ' +
              max
          );
        }
        return new FieldDecision(FieldAction.APPLY, value);
      }

      // REFERENCE: a HubSpot property cannot meaningfully carry a
      // Salesforce foreign key, and record-to-record links are the
      // associations' job, not a field sync's.
      // MULTIPICKLIST: the ';' delimiter collides with HubSpot's own
      // multi-value encoding; out of scope rather than half-supported.
      return refuseUnsupported(
        cfg,
        portal,
        sfField,
        hsProperty,
        logId,
        String.valueOf(t)
      );
    } catch (Exception e) {
      return refuseType(
        cfg,
        portal,
        sfField,
        hsProperty,
        rawForLog,
        logId,
        e.getMessage()
      );
    }
  }

  /** Whether the value is an ACTIVE option of this picklist. Compared
   *  case-insensitively on the API value, matching how the forward value map
   *  keys its lookups. */
  private static Boolean isValidPicklistValue(
    Schema.DescribeFieldResult dfr,
    String value
  ) {
    for (Schema.PicklistEntry entry : dfr.getPicklistValues()) {
      if (entry.isActive() && entry.getValue().equalsIgnoreCase(value))
        return true;
    }
    return false;
  }

  private static FieldDecision refuseType(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    String sfField,
    String hsProperty,
    String raw,
    String logId,
    String why
  ) {
    PortalSyncDeadLetter.log(
      cfg.sObjectName,
      logId,
      portal,
      'INBOUND_TYPE',
      hsProperty + ' = "' + raw + '" ' + why + ' -- ' + sfField + ' omitted'
    );
    return skip();
  }

  private static FieldDecision refuseUnsupported(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    String sfField,
    String hsProperty,
    String logId,
    String displayType
  ) {
    PortalSyncDeadLetter.log(
      cfg.sObjectName,
      'INBOUND_CONFIG',
      portal,
      'INBOUND_UNSUPPORTED_TYPE',
      sfField +
        ' is of type ' +
        displayType +
        ', which inbound does not write (mapped from ' +
        hsProperty +
        ')'
    );
    return skip();
  }

  // ---- Conflict resolution ------------------------------------------------

  /**
   * Whether HubSpot's copy is newer than Salesforce's, by more than the
   * configured tolerance.
   *
   * The Salesforce side is the PROVENANCE stamp, not LastModifiedDate. The
   * engine's own status DML bumps LastModifiedDate on every record it touches,
   * so using it would make Salesforce win every comparison and inbound would
   * appear to work while silently applying nothing.
   *
   * The tolerance band matters for a second, less obvious reason as well as
   * clock skew: an outbound push legitimately lands in HubSpot minutes AFTER
   * the Salesforce edit that caused it, so without a band every
   * Salesforce-originated change would look like a HubSpot win on the very
   * next poll.
   */
  @TestVisible
  private static Boolean hubSpotIsNewer(
    PortalSyncConfig.ObjectConfig cfg,
    SObject existing,
    Datetime hsModified
  ) {
    if (hsModified == null)
      return false; // no evidence => Salesforce keeps its value
    Datetime sfChanged;
    if (String.isNotBlank(cfg.contentChangedField)) {
      sfChanged = (Datetime) safeGet(existing, cfg.contentChangedField);
      // Records that predate the provenance field have never been stamped;
      // fall back to creation so they are not treated as infinitely old.
      if (sfChanged == null)
        sfChanged = (Datetime) safeGet(existing, 'CreatedDate');
    } else {
      sfChanged = (Datetime) safeGet(existing, 'LastModifiedDate');
    }
    if (sfChanged == null)
      return true; // nothing to lose to
    Integer skew = (cfg.inboundSkewSeconds != null)
      ? cfg.inboundSkewSeconds
      : PortalSyncConfig.DEFAULT_SKEW_SECONDS;
    return hsModified > sfChanged.addSeconds(skew);
  }

  // ---- Typed helpers ------------------------------------------------------

  /**
   * Value equality, typed.
   *
   * Numbers compare numerically, so HubSpot's "1000.5" and Salesforce's
   * 1000.50 are equal -- comparing them as text would rewrite the field on
   * every poll, which re-stamps Pending, which re-pushes, which bumps the
   * HubSpot timestamp: a genuine infinite loop on any Currency or Number
   * field.
   *
   * Strings compare CASE-SENSITIVELY, unlike Apex's == on Object operands. A
   * case-only edit in HubSpot is a real edit and must be applied.
   */
  @TestVisible
  private static Boolean valuesEqual(Object current, Object incoming) {
    if (current == null && incoming == null)
      return true;
    if (current == null || incoming == null)
      return false;
    if (
      current instanceof Decimal ||
      incoming instanceof Decimal ||
      current instanceof Integer ||
      incoming instanceof Integer ||
      current instanceof Long ||
      incoming instanceof Long ||
      current instanceof Double ||
      incoming instanceof Double
    ) {
      Decimal a = toDecimal(current);
      Decimal b = toDecimal(incoming);
      if (a == null || b == null)
        return false;
      // Subtraction, not equals(): Decimal.equals is scale-sensitive, so
      // 1000.50 and 1000.5 would compare unequal and the field would be
      // rewritten on every poll. Decimal.compareTo is not visible in Apex.
      return (a - b) == 0;
    }
    if (current instanceof String && incoming instanceof String) {
      return ((String) current).equals((String) incoming); // case-sensitive
    }
    return current == incoming;
  }

  private static Decimal toDecimal(Object o) {
    if (o instanceof Decimal)
      return (Decimal) o;
    if (o instanceof Integer)
      return Decimal.valueOf((Integer) o);
    if (o instanceof Long)
      return Decimal.valueOf((Long) o);
    if (o instanceof Double)
      return Decimal.valueOf(String.valueOf(o));
    if (o instanceof String) {
      try {
        return Decimal.valueOf((String) o);
      } catch (Exception e) {
        return null;
      }
    }
    return null;
  }

  /**
   * HubSpot dates arrive as epoch milliseconds (UTC midnight) or as
   * 'yyyy-MM-dd'.
   *
   * The epoch form MUST use dateGmt(), never date(). A batch runs as whoever
   * scheduled it, so date() would render a UTC-midnight epoch as the PREVIOUS
   * day for any user west of GMT -- the exact hazard the outbound formatDate
   * was written to avoid, in the other direction.
   */
  @TestVisible
  private static Date parseDate(String value) {
    String v = value.trim();
    if (v.isNumeric()) {
      return Datetime.newInstance(Long.valueOf(v)).dateGmt();
    }
    if (v.contains('T')) {
      Datetime parsed = parseDatetime(v);
      // An unparseable timestamp must raise, not silently become null --
      // convert()'s catch turns it into an INBOUND_TYPE dead letter.
      if (parsed == null)
        throw new IllegalArgumentException('is not a parseable date');
      return parsed.dateGmt();
    }
    return Date.valueOf(v);
  }

  /** Delegates to the protocol layer, so both directions parse HubSpot
   *  timestamps identically -- the inbound watermark and the outbound conflict
   *  check must never disagree about what a HubSpot date means. */
  @TestVisible
  private static Datetime parseDatetime(Object value) {
    return HubSpotService.parseHubSpotDatetime(value);
  }

  private static String trimToNull(Object raw) {
    if (raw == null)
      return null;
    String s = String.valueOf(raw).trim();
    return String.isBlank(s) ? null : s;
  }

  /** True when the value is a well-formed id FOR THIS OBJECT. The key-prefix
   *  check matters because the sf-id property is free text in HubSpot: a user
   *  can type anything into it, including another object's id. */
  @TestVisible
  private static Boolean isIdShaped(String value, String sObjectName) {
    if (value == null || (value.length() != 15 && value.length() != 18))
      return false;
    try {
      Id candidate = (Id) value;
      return candidate.getSObjectType()
        .getDescribe()
        .getName()
        .equalsIgnoreCase(sObjectName);
    } catch (Exception e) {
      return false;
    }
  }

  /** Reads a field that may not have been queried, without throwing. */
  private static Object safeGet(SObject record, String field) {
    try {
      return record.get(field);
    } catch (Exception e) {
      return null;
    }
  }

  // ---- Describe caches ----------------------------------------------------

  private static Map<String, Map<String, Schema.DescribeFieldResult>> fieldDescribesByObject = new Map<String, Map<String, Schema.DescribeFieldResult>>();

  private static Schema.DescribeFieldResult fieldDescribe(
    String sObjectName,
    String fieldName
  ) {
    Map<String, Schema.DescribeFieldResult> byField = fieldDescribesByObject.get(
      sObjectName
    );
    if (byField == null) {
      byField = new Map<String, Schema.DescribeFieldResult>();
      Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectName);
      if (sot != null) {
        for (
          Schema.SObjectField f : sot.getDescribe().fields.getMap().values()
        ) {
          Schema.DescribeFieldResult dfr = f.getDescribe();
          byField.put(dfr.getName().toLowerCase(), dfr);
        }
      }
      fieldDescribesByObject.put(sObjectName, byField);
    }
    return byField.get(fieldName.toLowerCase());
  }

  // DeveloperName (lowercased) -> RecordTypeId, for record types that are both
  // active and available to the running user. The inverse of the outbound
  // recordTypeDeveloperNames cache, and describe-only like it -- no SOQL.
  private static Map<String, Map<String, Id>> recordTypeIdsByObject = new Map<String, Map<String, Id>>();

  private static Map<String, Id> recordTypeIdsByDeveloperName(
    String sObjectName
  ) {
    Map<String, Id> byName = recordTypeIdsByObject.get(sObjectName);
    if (byName == null) {
      byName = new Map<String, Id>();
      Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectName);
      if (sot != null) {
        for (
          Schema.RecordTypeInfo info : sot.getDescribe().getRecordTypeInfos()
        ) {
          if (!info.isActive() || !info.isAvailable())
            continue;
          byName.put(
            info.getDeveloperName().toLowerCase(),
            info.getRecordTypeId()
          );
        }
      }
      recordTypeIdsByObject.put(sObjectName, byName);
    }
    return byName;
  }
}
