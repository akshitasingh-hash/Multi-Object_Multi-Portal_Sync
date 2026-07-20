/**
 * Self-healing backstop for one object. Re-asserts recently modified records with
 * a FULL archive-from-others sweep (archiveOthers = true), so it repairs both
 * missed upserts and any record that somehow lingers in a wrong portal. Schedule
 * nightly per object; it complements the 15-min outbox, it does not replace it.
 *
 * It writes status like the outbox batch, so a repaired record flips to Synced.
 * Residual gap (same as always): a record hard-deleted in Salesforce while the
 * integration was down longer than tombstones survive would need a HubSpot-side
 * orphan listing to catch -- add that separately if it matters.
 */
public with sharing class PortalSyncReconciliationBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Schedulable {

    private final PortalSyncConfig.ObjectConfig cfg;
    private Integer lookbackDays;

    public PortalSyncReconciliationBatch() { this('Contact', 2); }
    public PortalSyncReconciliationBatch(Integer lookbackDays) { this('Contact', lookbackDays); }
    public PortalSyncReconciliationBatch(String sObjectName) { this(sObjectName, 2); }
    public PortalSyncReconciliationBatch(String sObjectName, Integer lookbackDays) {
        this.cfg = PortalSyncConfig.objectConfig(sObjectName);
        if (this.cfg == null) {
            throw new IllegalArgumentException(
                'No Portal_Sync_Object__mdt configuration for SObject: ' + sObjectName);
        }
        this.lookbackDays = lookbackDays;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Set<String> fields = new Set<String>{ 'Id', cfg.portalField };
        fields.addAll(PortalSyncConfig.mappedSfFields(cfg.sObjectName));
        fields.addAll(PortalSyncConfig.associationSourceFields(cfg.sObjectName));
        return Database.getQueryLocator(
            'SELECT ' + String.join(new List<String>(fields), ', ') +
            ' FROM ' + cfg.sObjectName + ' WHERE LastModifiedDate = LAST_N_DAYS:' + this.lookbackDays
        );
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Map<Id, Boolean> success = PortalRouter.syncRecords(cfg, scope, true); // full sweep, bulk

        // Reassert associations (full create + archive diff) for records that
        // synced OK -- callout phase, before the DML below.
        List<SObject> synced = new List<SObject>();
        for (SObject record : scope) {
            if (success.get(record.Id) == true) synced.add(record);
        }
        PortalAssociationRouter.syncAssociations(cfg, synced);

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(cfg.sObjectName);
        List<SObject> updates = new List<SObject>();
        for (SObject record : scope) {
            SObject u = sot.newSObject((Id) record.Id);
            u.put(cfg.lastSyncField, System.now());
            u.put(cfg.statusField, success.get(record.Id)
                ? PortalSyncConfig.STATUS_SYNCED
                : PortalSyncConfig.STATUS_FAILED);
            updates.add(u);
        }
        if (!updates.isEmpty()) update updates;
        PortalSyncDeadLetter.flush();
    }

    public void finish(Database.BatchableContext bc) {}

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new PortalSyncReconciliationBatch(this.cfg.sObjectName, this.lookbackDays), PortalSyncConfig.BATCH_SCOPE);
    }
}
