/**
 * Owns outbox stamping for any synced object. Each object's thin trigger passes
 * its PortalSyncConfig.ObjectConfig, so all field reads/writes go through the
 * configured field names -- one handler serves Contact, Account, etc.
 *   - insert/update -> stamp Pending when the portal field or a mapped field changes
 *   - delete         -> write a tombstone so the outbox can archive from HubSpot
 *   - undelete       -> re-stamp the restored record as Pending so it re-syncs
 */
public with sharing class PortalSyncHandler {
  /**
   * Before insert/update stamping. Runs in a before-trigger, so it stamps the
   * records in place (no extra DML).
   *
   * TWO different questions are answered here, over TWO different field sets --
   * they look similar and are not interchangeable:
   *
   *   - Should this record be QUEUED for an outbound push? Watched set is
   *     PortalSyncConfig.outboundSfFields() -- only fields Salesforce may
   *     actually send somewhere. A field that is HS_to_SF in every portal it
   *     syncs to is absent from this set, which is precisely why an inbound
   *     write to a HubSpot-owned field cannot bounce back out.
   *   - Did the record's CONTENT change? Watched set is the wider
   *     mappedSfFields() -- any direction. A Salesforce edit to a HubSpot-owned
   *     field must still move the provenance clock (so "Salesforce is newer" is
   *     true on the next poll) even though it must not enqueue a push.
   *
   * Echo guard: on update we stamp only when the portal field or a sendable
   * mapped field actually changed. The native HS->SF connector's write-backs
   * touch only the HS_* status fields, so they never re-stamp Pending and the
   * queue drains. `oldMap` is null on insert (every new record enters the outbox).
   */
  public static void stampForSync(
    PortalSyncConfig.ObjectConfig cfg,
    List<SObject> newList,
    Map<Id, SObject> oldMap
  ) {
    Boolean isInsert = (oldMap == null);
    Set<String> sendableFields = PortalSyncConfig.outboundSfFields(
      cfg.sObjectName
    );
    Set<String> allMappedFields = PortalSyncConfig.mappedSfFields(
      cfg.sObjectName
    );
    Boolean tracksContent = String.isNotBlank(cfg.contentChangedField);
    for (SObject record : newList) {
      Boolean portalChanged = false;
      Boolean stamp = isInsert; // every new record is stamped
      Boolean contentChanged = isInsert;

      if (!isInsert) {
        SObject prior = oldMap.get(record.Id);
        portalChanged =
          record.get(cfg.portalField) != prior.get(cfg.portalField);
        Boolean sendableChanged = false;
        for (String f : sendableFields) {
          if (record.get(f) != prior.get(f)) {
            sendableChanged = true;
            break;
          }
        }
        for (String f : allMappedFields) {
          if (record.get(f) != prior.get(f)) {
            contentChanged = true;
            break;
          }
        }
        Boolean ownerChanged =
          cfg.syncOwner && (record.get('OwnerId') != prior.get('OwnerId'));
        stamp = portalChanged || sendableChanged || ownerChanged;
      }

      // Provenance is stamped independently of the outbox status, and BEFORE
      // the early return below -- a content change that does not warrant a
      // push still has to be recorded. Guarded on a configured field name
      // because put() with an unknown field throws, which would break every
      // save on an object whose provenance field was never deployed.
      if (contentChanged && tracksContent) {
        record.put(cfg.contentChangedField, System.now());
      }

      if (!stamp)
        continue;
      record.put(cfg.statusField, PortalSyncConfig.STATUS_PENDING);
      record.put(cfg.portalChangedField, portalChanged); // only true portal moves pay for the archive sweep
      record.put(cfg.retryCountField, 0);
    }
  }

  public static void enqueueDeletes(
    PortalSyncConfig.ObjectConfig cfg,
    List<SObject> oldList
  ) {
    List<HS_Sync_Tombstone__c> tombstones = new List<HS_Sync_Tombstone__c>();
    for (SObject record : oldList) {
      tombstones.add(
        new HS_Sync_Tombstone__c(
          SObject_Name__c = cfg.sObjectName,
          Record_Id__c = record.Id,
          Status__c = PortalSyncConfig.STATUS_PENDING,
          Retry_Count__c = 0
        )
      );
    }
    if (!tombstones.isEmpty())
      insert tombstones;
  }

  /**
   * Re-stamp existing records Pending by id, without a portal move. Used when
   * something OTHER than the record's own fields changed its HubSpot state --
   * e.g. an association junction row (OpportunityContactRole) was added or
   * removed, so the related Contact must re-run its association pass. Touches
   * only the status + retry fields (not the portal-changed flag), so the outbox
   * upserts without a needless archive sweep.
   */
  public static void stampByIds(
    PortalSyncConfig.ObjectConfig cfg,
    Set<Id> ids
  ) {
    if (ids == null || ids.isEmpty())
      return;
    Schema.SObjectType sot = Schema.getGlobalDescribe().get(cfg.sObjectName);
    List<SObject> updates = new List<SObject>();
    for (Id recId : ids) {
      SObject u = sot.newSObject(recId);
      u.put(cfg.statusField, PortalSyncConfig.STATUS_PENDING);
      u.put(cfg.retryCountField, 0);
      updates.add(u);
    }
    update updates;
  }

  public static void stampForResync(
    PortalSyncConfig.ObjectConfig cfg,
    List<SObject> restored
  ) {
    Schema.SObjectType sot = Schema.getGlobalDescribe().get(cfg.sObjectName);
    List<SObject> updates = new List<SObject>();
    for (SObject record : restored) {
      SObject u = sot.newSObject((Id) record.Id);
      u.put(cfg.statusField, PortalSyncConfig.STATUS_PENDING);
      u.put(cfg.portalChangedField, true); // re-assert portal membership on restore
      u.put(cfg.retryCountField, 0);
      updates.add(u);
    }
    if (!updates.isEmpty())
      update updates;
  }
}
