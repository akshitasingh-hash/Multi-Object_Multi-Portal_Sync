/**
 * Opportunity outbox stamping. Mirror of ContactPortalSync/AccountPortalSync for
 * Opportunity: before insert/update stamps the sync status field on create or when
 * the portal field / a mapped field changes; delete/undelete cover deletes and
 * restores. All logic lives in the generic PortalSyncHandler; this trigger just
 * supplies Opportunity's ObjectConfig.
 */
trigger OpportunityPortalSync on Opportunity (before insert, before update, after delete, after undelete) {
    PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig('Opportunity');
    if (cfg == null) return; // Opportunity not configured for portal sync
    if (Trigger.isBefore) {
        if (Trigger.isInsert || Trigger.isUpdate) {
            PortalSyncHandler.stampForSync(cfg, Trigger.new, Trigger.oldMap);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isDelete) {
            PortalSyncHandler.enqueueDeletes(cfg, Trigger.old);
        } else if (Trigger.isUndelete) {
            PortalSyncHandler.stampForResync(cfg, Trigger.new);
        }
    }
}
