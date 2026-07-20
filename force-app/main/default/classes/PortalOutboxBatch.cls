/**
 * Drains one object's outbox. A before-save Flow/trigger stamps the object's
 * status field = 'Pending' (and the portal-changed flag) whenever a mapped field
 * or the portal field changes; this batch does the HubSpot work.
 *
 * Generic over object type: it is constructed with an SObject API name and reads
 * everything else (which fields to select, which HubSpot object to hit) from the
 * matching Portal_Sync_Object__mdt row via PortalSyncConfig.ObjectConfig.
 *
 * Ordering inside execute() is deliberate: ALL callouts first, then ALL DML
 * (status updates + dead-letter flush). Claiming rows up front would mean
 * DML-before-callout, which throws. Overlapping runs are prevented by
 * PortalSyncScheduler (per object, via the concrete subclass name), not by row
 * claiming.
 *
 * A distinct concrete subclass per object (ContactOutboxBatch, AccountOutboxBatch)
 * gives the scheduler a per-object overlap guard keyed on ApexClass.Name, so two
 * objects can drain concurrently without one blocking the other.
 */
public virtual with sharing class PortalOutboxBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts {

    protected final PortalSyncConfig.ObjectConfig cfg;

    public PortalOutboxBatch(String sObjectName) {
        this.cfg = PortalSyncConfig.objectConfig(sObjectName);
        if (this.cfg == null) {
            throw new IllegalArgumentException(
                'No Portal_Sync_Object__mdt configuration for SObject: ' + sObjectName);
        }
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String pending = PortalSyncConfig.STATUS_PENDING;
        String failed  = PortalSyncConfig.STATUS_FAILED;
        Integer maxRetries = PortalSyncConfig.MAX_RETRIES;

        Set<String> fields = new Set<String>{
            'Id', cfg.portalField, cfg.portalChangedField, cfg.retryCountField
        };
        fields.addAll(PortalSyncConfig.mappedSfFields(cfg.sObjectName));
        // Lookup-source association FKs (e.g. AccountId) so the association pass
        // can read the related record id without a second query.
        fields.addAll(PortalSyncConfig.associationSourceFields(cfg.sObjectName));

        String soql =
            'SELECT ' + String.join(new List<String>(fields), ', ') +
            ' FROM ' + cfg.sObjectName +
            ' WHERE ' + cfg.statusField + ' = :pending ' +
            '    OR (' + cfg.statusField + ' = :failed AND ' + cfg.retryCountField + ' < :maxRetries)';
        return Database.getQueryLocator(soql);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        // 1) Callouts only, in bulk. The router takes one archiveOthers flag, so
        // split the scope by the portal-changed flag: only real portal moves pay
        // for the archive sweep; routine field edits just upsert.
        List<SObject> moved = new List<SObject>();
        List<SObject> plain = new List<SObject>();
        for (SObject record : scope) {
            if (record.get(cfg.portalChangedField) == true) moved.add(record); else plain.add(record);
        }
        Map<Id, Boolean> success = new Map<Id, Boolean>();
        success.putAll(PortalRouter.syncRecords(cfg, plain, false));
        success.putAll(PortalRouter.syncRecords(cfg, moved, true));

        // 1b) Associations for records that synced OK -- still callout phase, so
        // it runs before any DML. Failures dead-letter but don't fail the record
        // (the field sync succeeded; a bad link self-heals on the next pass).
        List<SObject> synced = new List<SObject>();
        for (SObject record : scope) {
            if (success.get(record.Id) == true) synced.add(record);
        }
        PortalAssociationRouter.syncAssociations(cfg, synced);

        // 2) DML only, after every callout is done.
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(cfg.sObjectName);
        List<SObject> updates = new List<SObject>();
        for (SObject record : scope) {
            Boolean ok = success.get(record.Id);
            SObject u = sot.newSObject((Id) record.Id);
            u.put(cfg.lastSyncField, System.now());
            if (ok) {
                u.put(cfg.statusField, PortalSyncConfig.STATUS_SYNCED);
                u.put(cfg.portalChangedField, false);
                u.put(cfg.syncMessageField, null);
            } else {
                u.put(cfg.statusField, PortalSyncConfig.STATUS_FAILED);
                Object priorObj = record.get(cfg.retryCountField);
                Integer prior = (priorObj == null) ? 0 : ((Decimal) priorObj).intValue();
                u.put(cfg.retryCountField, prior + 1);
                u.put(cfg.syncMessageField, 'See PortalSyncDeadLetter for detail');
            }
            updates.add(u);
        }
        if (!updates.isEmpty()) update updates;
        PortalSyncDeadLetter.flush();
    }

    public void finish(Database.BatchableContext bc) {}
}
