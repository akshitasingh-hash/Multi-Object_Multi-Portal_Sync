/**
 * Contact outbox stamping. Before insert/update stamps the sync status field on
 * create or when the portal field / a mapped field changes -- the watched-field
 * set is driven entirely by the active HubSpot_Field_Mapping__mdt rows for
 * Contact, so mappings change without a code or flow edit. Delete/undelete cover
 * the cases stamping in place cannot. All logic lives in the generic
 * PortalSyncHandler; this trigger just supplies Contact's ObjectConfig.
 */
trigger ContactPortalSync on Contact (before insert, before update, after delete, after undelete) {
    PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig('Contact');
    if (cfg == null) return; // Contact not configured for portal sync
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
