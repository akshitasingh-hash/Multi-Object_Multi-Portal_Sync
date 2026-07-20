/**
 * Keeps Deal<->Contact associations fresh. OpportunityContactRole is the junction
 * behind the Contact->Opportunity association (Portal_Sync_Association__mdt), and
 * a role added, moved, or removed changes a Contact's deal links without touching
 * any mapped Contact field -- so the Contact outbox would not otherwise re-run.
 * This re-stamps the affected Contact(s) Pending; the next 15-min Contact outbox
 * reasserts the association diff. Delete/undelete matter because a removed role
 * must archive the link, and a restored one must recreate it.
 */
trigger OpportunityContactRoleSync on OpportunityContactRole (
        after insert, after update, after delete, after undelete) {

    PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig('Contact');
    if (cfg == null) return; // Contact not configured for portal sync

    Set<Id> contactIds = new Set<Id>();
    List<OpportunityContactRole> rows = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (OpportunityContactRole r : rows) {
        if (r.ContactId != null) contactIds.add(r.ContactId);
    }
    // On update the role could have been re-pointed; cover the prior contact too.
    if (Trigger.isUpdate) {
        for (OpportunityContactRole r : Trigger.old) {
            if (r.ContactId != null) contactIds.add(r.ContactId);
        }
    }
    PortalSyncHandler.stampByIds(cfg, contactIds);
}
