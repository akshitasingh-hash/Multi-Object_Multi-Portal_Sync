/**
 * Drains delete tombstones for every synced object. A record hard-deleted in
 * Salesforce can never be seen by the reconciliation batch (the row is gone), so
 * the after-delete trigger writes a tombstone here (tagged with SObject_Name__c)
 * and this batch archives that record from every portal. On success the tombstone
 * is deleted; on failure it is retried up to MAX_RETRIES. Callout-first, DML-last,
 * same as the outbox batch.
 *
 * One class serves all objects: the scope is grouped by SObject_Name__c and each
 * group is archived under its own Portal_Sync_Object__mdt config.
 */
public with sharing class TombstoneOutboxBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts {

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String pending = PortalSyncConfig.STATUS_PENDING;
        String failed  = PortalSyncConfig.STATUS_FAILED;
        Integer maxRetries = PortalSyncConfig.MAX_RETRIES;
        return Database.getQueryLocator(
            'SELECT Id, Record_Id__c, SObject_Name__c, Retry_Count__c FROM HS_Sync_Tombstone__c ' +
            'WHERE Status__c = :pending ' +
            '   OR (Status__c = :failed AND Retry_Count__c < :maxRetries)'
        );
    }

    public void execute(Database.BatchableContext bc, List<HS_Sync_Tombstone__c> scope) {
        // 1) Callouts only, in bulk -- archive every tombstoned record from all
        // enabled portals, one object at a time. `failed` accumulates the record
        // ids still present in HubSpot after the sweep.
        Map<String, List<String>> idsByObject = new Map<String, List<String>>();
        for (HS_Sync_Tombstone__c t : scope) {
            String obj = t.SObject_Name__c;
            if (!idsByObject.containsKey(obj)) idsByObject.put(obj, new List<String>());
            idsByObject.get(obj).add(t.Record_Id__c);
        }
        Set<String> failed = new Set<String>();
        for (String obj : idsByObject.keySet()) {
            PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig(obj);
            if (cfg == null) {
                // Unknown/removed object config -> can't archive; treat as failed so
                // the tombstone is retried (an admin may re-add the config).
                failed.addAll(idsByObject.get(obj));
                continue;
            }
            failed.addAll(PortalRouter.archiveEverywhere(cfg, idsByObject.get(obj)));
        }

        // 2) DML only.
        List<HS_Sync_Tombstone__c> toUpdate = new List<HS_Sync_Tombstone__c>();
        List<HS_Sync_Tombstone__c> toDelete = new List<HS_Sync_Tombstone__c>();
        for (HS_Sync_Tombstone__c t : scope) {
            if (!failed.contains(t.Record_Id__c)) {
                toDelete.add(t); // fully archived -> remove the tombstone
            } else {
                Integer prior = (t.Retry_Count__c == null) ? 0 : t.Retry_Count__c.intValue();
                toUpdate.add(new HS_Sync_Tombstone__c(
                    Id = t.Id,
                    Status__c = PortalSyncConfig.STATUS_FAILED,
                    Retry_Count__c = prior + 1
                ));
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!toDelete.isEmpty()) delete toDelete;
        PortalSyncDeadLetter.flush();
    }

    public void finish(Database.BatchableContext bc) {}
}
