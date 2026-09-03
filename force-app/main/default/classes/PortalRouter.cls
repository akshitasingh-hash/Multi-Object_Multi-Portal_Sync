/**
 * The routing brain, shared by the outbox batch and the reconciliation batch.
 * Generic over object type: it is handed a PortalSyncConfig.ObjectConfig and
 * routes any SObject, so the same logic drives contacts, companies, etc.
 *
 * syncRecords upserts each record into the portal(s) matching its portal field.
 * It archives from the OTHER portals only when archiveOthers=true -- the outbox
 * passes this per group (the record's portal-changed flag), so routine field
 * edits skip the archive sweep and only real portal moves pay for it. The
 * reconciliation batch passes true to stay fully self-healing.
 *
 * It is BULK: records are grouped by portal and pushed through HubSpot's batch
 * endpoints, so a scope of N records costs O(enabled portals) callouts instead
 * of O(N). This is what lets the outbox handle mass changes.
 *
 * Returns sfId -> TRUE on full success. Failures are BUFFERED in
 * PortalSyncDeadLetter; the caller must PortalSyncDeadLetter.flush() AFTER all
 * callouts (never between them -- DML between callouts throws in Apex).
 */
public with sharing class PortalRouter {
  public static Map<Id, Boolean> syncRecords(
    PortalSyncConfig.ObjectConfig cfg,
    List<SObject> records,
    Boolean archiveOthers
  ) {
    Map<Id, Boolean> result = new Map<Id, Boolean>();
    if (records == null || records.isEmpty())
      return result;

    // portal -> (sfId -> mapped props) to upsert
    Map<String, Map<String, Map<String, Object>>> upsertByPortal = new Map<String, Map<String, Map<String, Object>>>();
    // portal -> set of sfIds to archive
    Map<String, Set<String>> archiveByPortal = new Map<String, Set<String>>();

    List<String> enabled = PortalSyncConfig.allPortalValues();

    // Owner ids only mean something within one HubSpot account, so this is
    // fetched per portal, lazily -- only the first time a portal is actually
    // touched below, not eagerly for every enabled portal up front.
    Map<String, Map<String, String>> ownerMapByPortal = new Map<String, Map<String, String>>();

    // Needed by the Bidirectional comparison below, which has to read each
    // record's provenance stamp after the payloads are built.
    Map<String, SObject> recordsBySfId = new Map<String, SObject>();

    for (SObject record : records) {
      String sfId = record.Id;
      result.put(record.Id, true);
      recordsBySfId.put(sfId, record);

      // The portal field is multiselect -> a record can belong to several portals.
      Set<String> selected = PortalSyncConfig.selectedPortals(record, cfg);

      if (selected.isEmpty()) {
        // Belongs to no enabled portal -> should exist nowhere.
        for (String p : enabled)
          addTo(archiveByPortal, p, sfId);
        continue;
      }

      // Properties are resolved per portal: each portal receives only the
      // fields whose mapping opts into it (Syncs_To_*).
      for (String p : selected) {
        if (!upsertByPortal.containsKey(p)) {
          upsertByPortal.put(p, new Map<String, Map<String, Object>>());
        }
        Map<String, Object> props = HubSpotService.mapProperties(
          record,
          cfg.sObjectName,
          p
        );
        if (cfg.syncOwner) {
          if (!ownerMapByPortal.containsKey(p)) {
            Map<String, String> ownerFailed = new Map<String, String>();
            ownerMapByPortal.put(
              p,
              HubSpotService.ownerIdsByEmail(p, ownerFailed)
            );
            for (String detail : ownerFailed.values()) {
              PortalSyncDeadLetter.log(
                cfg.sObjectName,
                'OWNERS',
                p,
                'OWNER_RESOLVE',
                detail
              );
            }
          }
          String ownerEmail = ownerEmailOf(record);
          if (ownerEmail != null) {
            String hsOwnerId = ownerMapByPortal.get(p)
              .get(ownerEmail.toLowerCase());
            if (hsOwnerId != null)
              props.put('hubspot_owner_id', hsOwnerId);
          }
        }
        upsertByPortal.get(p).put(sfId, props);
      }
      if (archiveOthers) {
        for (String p : enabled) {
          if (!selected.contains(p))
            addTo(archiveByPortal, p, sfId);
        }
      }
    }

    // Shared-ownership check, BEFORE the upserts and only where it applies.
    // Skipped entirely -- no extra callout at all -- unless some field on
    // this object is actually configured Bidirectional somewhere.
    if (PortalSyncConfig.hasBidirectionalFields(cfg.sObjectName)) {
      for (String p : upsertByPortal.keySet()) {
        deferToNewerHubSpotValues(
          cfg,
          p,
          upsertByPortal.get(p),
          recordsBySfId,
          result
        );
      }
    }

    // Callouts: all upserts, then all archives. Failures mark the record and
    // buffer a dead-letter row; the caller flushes after every callout.
    for (String p : upsertByPortal.keySet()) {
      Map<String, String> failed = HubSpotService.batchUpsertBySfId(
        cfg,
        p,
        upsertByPortal.get(p)
      );
      for (String sfId : failed.keySet()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          p,
          'UPSERT',
          failed.get(sfId)
        );
        result.put((Id) sfId, false);
      }
    }
    for (String p : archiveByPortal.keySet()) {
      Map<String, String> failed = HubSpotService.batchArchiveBySfId(
        cfg,
        p,
        archiveByPortal.get(p)
      );
      for (String sfId : failed.keySet()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          p,
          'ARCHIVE',
          failed.get(sfId)
        );
        result.put((Id) sfId, false);
      }
    }
    return result;
  }

  /**
   * Bulk archive from every enabled portal (for hard-deleted records, whose
   * portal membership is gone). Returns the sfIds that failed to fully archive.
   */
  public static Set<String> archiveEverywhere(
    PortalSyncConfig.ObjectConfig cfg,
    List<String> sfIds
  ) {
    Set<String> failed = new Set<String>();
    Set<String> ids = new Set<String>(sfIds);
    if (ids.isEmpty())
      return failed;
    for (String p : PortalSyncConfig.allPortalValues()) {
      Map<String, String> f = HubSpotService.batchArchiveBySfId(cfg, p, ids);
      for (String sfId : f.keySet()) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          p,
          'ARCHIVE',
          f.get(sfId)
        );
        failed.add(sfId);
      }
    }
    return failed;
  }

  /**
   * Strip Bidirectional properties from this portal's payload where HubSpot's
   * copy is NEWER than Salesforce's, so the outbound leg honours the same
   * newest-modified-wins rule the inbound leg does.
   *
   * Without this, the rule would exist on one side only, which is no rule at
   * all. Concretely: a Salesforce edit at 10:00 stamps Pending; a HubSpot user
   * edits the same property at 10:02; the 10:05 drain pushes the Salesforce
   * value and bumps hs_lastmodifieddate. By the time inbound polls at 10:15
   * both sides agree and there is nothing left to arbitrate -- the HubSpot edit
   * is gone, and so is the evidence.
   *
   * SF_to_HS fields are never touched here: Salesforce owns them outright, so
   * they are pushed regardless of what HubSpot's timestamp says.
   *
   * On a read failure the record is FAILED rather than pushed, and rather than
   * silently pruned. Pushing would clobber a value we could not verify; pruning
   * while letting the upsert succeed would flip the record to Synced and lose
   * the Salesforce edit for good. Failing leaves it to retry.
   */
  private static void deferToNewerHubSpotValues(
    PortalSyncConfig.ObjectConfig cfg,
    String portal,
    Map<String, Map<String, Object>> payloadBySfId,
    Map<String, SObject> recordsBySfId,
    Map<Id, Boolean> result
  ) {
    Set<String> bidirectional = PortalSyncConfig.bidirectionalSfFields(
      cfg.sObjectName,
      portal
    );
    if (bidirectional.isEmpty() || payloadBySfId.isEmpty())
      return;

    Map<String, String> fieldMap = PortalSyncConfig.fieldMapFor(
      cfg.sObjectName,
      portal
    );
    List<String> properties = new List<String>{ cfg.inboundModifiedProperty };
    for (String sfField : bidirectional) {
      String hsProperty = fieldMap.get(sfField);
      if (hsProperty != null)
        properties.add(hsProperty);
    }

    Map<String, String> failed = new Map<String, String>();
    Map<String, Map<String, Object>> hubSpotProps = HubSpotService.batchReadBySfId(
      cfg,
      portal,
      new List<String>(payloadBySfId.keySet()),
      properties,
      failed
    );

    Integer skew = (cfg.inboundSkewSeconds != null)
      ? cfg.inboundSkewSeconds
      : PortalSyncConfig.DEFAULT_SKEW_SECONDS;

    for (String sfId : new List<String>(payloadBySfId.keySet())) {
      if (failed.containsKey(sfId)) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          sfId,
          portal,
          'BIDI_COMPARE',
          'Could not read HubSpot values to resolve shared-ownership fields: ' +
            failed.get(sfId) +
            ' -- record not pushed, will retry'
        );
        payloadBySfId.remove(sfId);
        result.put((Id) sfId, false);
        continue;
      }
      Map<String, Object> remote = hubSpotProps.get(sfId);
      if (remote == null)
        continue; // not in this portal yet -- nothing to lose

      Datetime hsModified = HubSpotService.parseHubSpotDatetime(
        remote.get(cfg.inboundModifiedProperty)
      );
      if (hsModified == null)
        continue;

      Datetime sfChanged = provenanceOf(cfg, recordsBySfId.get(sfId));
      if (sfChanged != null && hsModified <= sfChanged.addSeconds(skew))
        continue;

      // HubSpot's copy is genuinely newer: leave those properties alone and
      // let the next inbound poll bring the newer value into Salesforce.
      Map<String, Object> payload = payloadBySfId.get(sfId);
      for (String sfField : bidirectional) {
        String hsProperty = fieldMap.get(sfField);
        if (hsProperty != null)
          payload.remove(hsProperty);
      }
    }
  }

  /** When a mapped field on this record last really changed in Salesforce.
   *  Never LastModifiedDate when a provenance field is configured -- the
   *  engine's own status DML bumps LastModifiedDate on every record it
   *  touches, so it would report "just now" for everything. */
  private static Datetime provenanceOf(
    PortalSyncConfig.ObjectConfig cfg,
    SObject record
  ) {
    if (record == null)
      return null;
    try {
      if (String.isNotBlank(cfg.contentChangedField)) {
        Datetime stamped = (Datetime) record.get(cfg.contentChangedField);
        if (stamped != null)
          return stamped;
        return (Datetime) record.get('CreatedDate');
      }
      return (Datetime) record.get('LastModifiedDate');
    } catch (Exception e) {
      return null; // not queried -> no evidence Salesforce is newer
    }
  }

  private static void addTo(
    Map<String, Set<String>> m,
    String portal,
    String sfId
  ) {
    if (!m.containsKey(portal))
      m.put(portal, new Set<String>());
    m.get(portal).add(sfId);
  }

  /** The record's Owner's email, or null if Owner.Email wasn't queried/set. */
  private static String ownerEmailOf(SObject record) {
    SObject owner = record.getSObject('Owner');
    return (owner != null) ? (String) owner.get('Email') : null;
  }
}
