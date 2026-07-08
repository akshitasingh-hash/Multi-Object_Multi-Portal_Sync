/**
 * Runs on a schedule (every 15 min) and launches the outbox batches for every
 * active object plus the shared tombstone batch. It will NOT launch a batch that
 * is already running, which is how we avoid two runs touching the same rows --
 * that overlap guard is what lets the batches use the callout-first / DML-last
 * pattern instead of claiming rows up front.
 *
 * Each object has its own outbox batch class (Portal_Sync_Object__mdt.
 * Outbox_Batch_Class__c, e.g. ContactOutboxBatch / AccountOutboxBatch), so the
 * per-class overlap guard is per-object and two objects can drain concurrently.
 *
 * Schedule (from anonymous Apex or Setup):
 *   System.schedule('HS Outbox :00', '0 0  * * * ?', new PortalSyncScheduler());
 *   System.schedule('HS Outbox :15', '0 15 * * * ?', new PortalSyncScheduler());
 *   System.schedule('HS Outbox :30', '0 30 * * * ?', new PortalSyncScheduler());
 *   System.schedule('HS Outbox :45', '0 45 * * * ?', new PortalSyncScheduler());
 * (Cron fires at most hourly per expression, so four entries give 15-min cadence.)
 */
public with sharing class PortalSyncScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        for (PortalSyncConfig.ObjectConfig cfg : PortalSyncConfig.activeObjects()) {
            String batchClass = cfg.outboxBatchClass;
            if (String.isBlank(batchClass) || isRunning(batchClass)) continue;
            Type t = Type.forName(batchClass);
            if (t == null) continue; // misconfigured class name -> skip, don't blow up the run
            Database.Batchable<SObject> job = (Database.Batchable<SObject>) t.newInstance();
            Database.executeBatch(job, PortalSyncConfig.BATCH_SCOPE);
        }
        if (!isRunning('TombstoneOutboxBatch')) {
            Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        }
    }

    private Boolean isRunning(String className) {
        List<AsyncApexJob> jobs = [
            SELECT Id
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
              AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
              AND ApexClass.Name = :className
            LIMIT 1
        ];
        return !jobs.isEmpty();
    }
}
