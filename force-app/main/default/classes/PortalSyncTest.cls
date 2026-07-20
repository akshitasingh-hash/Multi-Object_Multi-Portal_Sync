/**
 * Assumes Contact.Portal__c, the HS_* governance fields, and
 * HS_Sync_Tombstone__c exist in the org (all part of this deployment). The
 * ContactPortalSync trigger does create/update stamping; most tests below stamp
 * the fields directly so they exercise the Apex outbox path in isolation, and
 * the trigger* tests cover the stamping trigger itself.
 */
@isTest
private class PortalSyncTest {

    private static Contact makePending(String portal, Boolean portalChanged) {
        Contact c = new Contact(
            LastName = 'T', Email = 't' + Math.round(Math.random()*100000) + '@ex.com',
            Portal__c = portal
        );
        insert c;
        // Pin the exact status + portalChanged flag this test needs (the trigger
        // stamps Pending on insert with portalChanged=false).
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
        c.HS_Portal_Changed__c = portalChanged;
        update c;
        return c;
    }

    // Bulk-stamp n pending contacts in 2 DML statements (per-record insert+update
    // would blow the 150-statement limit on large scopes).
    private static List<Contact> makePendingBulk(Integer n, String portal, Boolean portalChanged) {
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < n; i++) {
            contacts.add(new Contact(LastName = 'B' + i, Email = 'b' + i + '@ex.com', Portal__c = portal));
        }
        insert contacts;
        for (Contact c : contacts) {
            c.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
            c.HS_Portal_Changed__c = portalChanged;
        }
        update contacts;
        return contacts;
    }

    @isTest
    static void outboxHandlesBulkChangesAcrossChunks() {
        // 150 pending contacts in one execute exercises multi-chunk batch upsert
        // (HubSpot caps a batch at 100), proving mass changes drain in one pass.
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        makePendingBulk(150, 'TriBU', false);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), 200); // whole set in one execute
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Contact WHERE HS_Sync_Status__c != :PortalSyncConfig.STATUS_SYNCED],
            'every contact in a bulk change should end Synced');
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void outboxFailedUpsertDeadLetters() {
        // Batch upsert returns 500 -> record marked Failed, retry bumped, and a
        // dead-letter row buffered/flushed. Covers the batch failure branch.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.failBatch = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Contact c = makePending('TriBU', false);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c, HS_Retry_Count__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_FAILED, after.HS_Sync_Status__c);
        System.assertEquals(1, after.HS_Retry_Count__c, 'retry incremented on failure');
        List<PortalSyncDeadLetter__c> dead = [SELECT Error__c FROM PortalSyncDeadLetter__c];
        System.assertEquals(1, dead.size(), 'a failed batch upsert should buffer a dead-letter row');
        System.assert(dead[0].Error__c.contains('HTTP 500'),
            'dead letter should carry the real HubSpot status, got: ' + dead[0].Error__c);
    }

    @isTest
    static void outboxCalloutExceptionDoesNotAbortRun() {
        // A callout-level exception (timeout etc.) must fail only the affected
        // records and let execute() complete -- not throw out of the whole batch.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.throwCallout = true;
        Test.setMock(HttpCalloutMock.class, mock);
        makePendingBulk(3, 'TriBU', false);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        // If the exception had aborted execute(), status updates never run and the
        // rows would still be Pending. They are Failed -> the run completed.
        System.assertEquals(3, [SELECT COUNT() FROM Contact WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_FAILED]);
        System.assertEquals(3, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
        PortalSyncDeadLetter__c d = [SELECT Error__c FROM PortalSyncDeadLetter__c LIMIT 1];
        System.assert(d.Error__c.contains('Callout error'),
            'the callout exception should be captured: ' + d.Error__c);
    }

    @isTest
    static void outboxPartialUpsertDeadLettersOnlyFailedRecord() {
        // 207 multi-status: HubSpot accepts all but one record. Only the rejected
        // one is dead-lettered/Failed; the rest are Synced.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.partialUpsert = true;
        Test.setMock(HttpCalloutMock.class, mock);
        makePendingBulk(3, 'TriBU', false);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Contact WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_FAILED],
            'only the record HubSpot rejected should be Failed');
        System.assertEquals(2, [SELECT COUNT() FROM Contact WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_SYNCED]);
        System.assertEquals(1, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void outboxArchivesContactInNoPortal() {
        // A Pending contact in no enabled portal must be archived everywhere.
        // returnExisting=true forces batch/read to resolve an id, exercising the
        // archive resolve->archive path (batch read + batch archive).
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Contact c = makePending('', false); // blank Portal__c -> selectedPortals empty
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    // Stamp a Pending tombstone directly, the way the after-delete trigger would,
    // so the batch is exercised without depending on the org's delete automation.
    private static HS_Sync_Tombstone__c makeTombstone() {
        Contact c = new Contact(LastName = 'Tomb', Portal__c = 'TriBU');
        insert c;
        HS_Sync_Tombstone__c t = new HS_Sync_Tombstone__c(
            SObject_Name__c = 'Contact', Record_Id__c = c.Id,
            Status__c = PortalSyncConfig.STATUS_PENDING, Retry_Count__c = 0
        );
        insert t;
        return t;
    }

    @isTest
    static void tombstoneOutboxArchivesAndDrains() {
        // Bulk archive succeeds (returnExisting resolves an id) -> tombstone gone.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        makeTombstone();
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'archived tombstone should be deleted');
    }

    @isTest
    static void tombstoneFailureRetries() {
        // Batch archive fails -> tombstone kept and marked Failed with retry bump.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.failBatch = true;
        Test.setMock(HttpCalloutMock.class, mock);
        makeTombstone();
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        List<HS_Sync_Tombstone__c> after = [SELECT Status__c, Retry_Count__c FROM HS_Sync_Tombstone__c];
        System.assertEquals(1, after.size(), 'failed archive keeps the tombstone for retry');
        System.assertEquals(PortalSyncConfig.STATUS_FAILED, after[0].Status__c);
        System.assertEquals(1, after[0].Retry_Count__c);
    }

    @isTest
    static void outboxSyncsPendingContact() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Contact c = makePending('TriBU', false);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void portalMoveArchivesOthers() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Contact c = makePending('TriBU', true); // portal changed -> archive others
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(false, after.HS_Portal_Changed__c, 'flag cleared after sync');
    }

    @isTest
    static void multiselectSyncsEnabledPortalsOnly() {
        // Portal__c is a multiselect: value arrives semicolon-delimited. Include
        // a disabled portal (Carl Software) to prove it is ignored, not archive-everywhere.
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Contact c = makePending('TriBU;Carl Software', true);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c,
            'multiselect value should upsert to the enabled portal, not fall into archive-everywhere');
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void deleteWritesAndDrainsTombstone() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Contact c = new Contact(LastName = 'Del', Portal__c = 'Berger-Levrault Spain');
        insert c;
        delete c; // after-delete trigger writes a tombstone
        System.assertEquals(1, [SELECT COUNT() FROM HS_Sync_Tombstone__c]);
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'tombstone removed after successful archive');
    }

    @isTest
    static void schedulerLaunchesBatches() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        makePending('Carl Software', false);
        Test.startTest();
        new PortalSyncScheduler().execute(null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void reconciliationRuns() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        insert new Contact(LastName = 'Rec', Portal__c = 'TriBU');
        Test.startTest();
        Database.executeBatch(new PortalSyncReconciliationBatch(30), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void triggerStampsPendingOnInsert() {
        Contact c = new Contact(LastName = 'New', Portal__c = 'TriBU');
        insert c;
        Contact after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
                         FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'every new contact should be stamped Pending by the before-insert trigger');
        System.assertEquals(false, after.HS_Portal_Changed__c, 'no portal move on create');
        System.assertEquals(0, after.HS_Retry_Count__c);
    }

    @isTest
    static void triggerReStampsOnMappedFieldChange() {
        // The watched-field set comes from the active HubSpot_Field_Mapping__mdt
        // rows via PortalSyncConfig.mappedSfFields(); FirstName is one of them.
        Contact c = new Contact(LastName = 'Old', Portal__c = 'TriBU');
        insert c;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED; // reach a terminal state
        update c;
        c.FirstName = 'Changed';
        update c;
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'changing a mapped field should re-stamp Pending');
    }

    @isTest
    static void triggerEchoGuardIgnoresStatusOnlyUpdate() {
        // The native HS->SF connector writes back only the HS_* status fields.
        // That must NOT re-stamp Pending, or the queue would never drain.
        Contact c = new Contact(LastName = 'Echo', Portal__c = 'TriBU');
        insert c;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED;
        update c; // touches only an HS_* field -> no mapped/portal change
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c,
            'a status-only write-back must not re-stamp Pending');
    }

    @isTest
    static void triggerStampsPortalMove() {
        Contact c = new Contact(LastName = 'Move', Portal__c = 'TriBU');
        insert c;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED;
        update c;
        c.Portal__c = 'Berger-Levrault Spain'; // a real portal move
        update c;
        Contact after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'a portal move should re-stamp Pending');
        System.assertEquals(true, after.HS_Portal_Changed__c,
            'a portal move should set HS_Portal_Changed__c so the batch archives the old portal');
    }

    @isTest
    static void undeleteRestamps() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Contact c = new Contact(LastName = 'Undel', Portal__c = 'Berger-Levrault Spain');
        insert c;
        delete c;
        Test.startTest();
        undelete c;
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c);
    }

    // ---- Account: the generic engine driving a second object ----------------
    // These prove the same outbox/router/handler code syncs Account via its
    // Portal_Sync_Object__mdt config (HubSpot companies, account_id_sf), with no
    // Contact-specific assumptions leaking in.

    private static Account makePendingAccount(String portal, Boolean portalChanged) {
        Account a = new Account(Name = 'Acme ' + Math.round(Math.random()*100000), Portal__c = portal);
        insert a;
        // Pin the exact status + portalChanged flag this test needs (the trigger
        // stamps Pending on insert with portalChanged=false).
        a.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
        a.HS_Portal_Changed__c = portalChanged;
        update a;
        return a;
    }

    @isTest
    static void accountOutboxSyncsPending() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Account a = makePendingAccount('TriBU', false);
        Test.startTest();
        Database.executeBatch(new AccountOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void accountPortalMoveArchivesOthers() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Account a = makePendingAccount('TriBU', true); // portal changed -> archive others
        Test.startTest();
        Database.executeBatch(new AccountOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Account after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(false, after.HS_Portal_Changed__c, 'flag cleared after sync');
    }

    @isTest
    static void accountArchivesInNoPortal() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true; // force batch/read to resolve a company id to archive
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = makePendingAccount('', false); // blank Portal__c -> selectedPortals empty
        Test.startTest();
        Database.executeBatch(new AccountOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void accountFailedUpsertDeadLetters() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.failBatch = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = makePendingAccount('TriBU', false);
        Test.startTest();
        Database.executeBatch(new AccountOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Account after = [SELECT HS_Sync_Status__c, HS_Retry_Count__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_FAILED, after.HS_Sync_Status__c);
        System.assertEquals(1, after.HS_Retry_Count__c, 'retry incremented on failure');
        List<PortalSyncDeadLetter__c> dead = [SELECT SObject_Name__c FROM PortalSyncDeadLetter__c];
        System.assertEquals(1, dead.size(), 'a failed Account upsert should buffer a dead-letter row');
        System.assertEquals('Account', dead[0].SObject_Name__c, 'dead letter should be tagged with the object');
    }

    @isTest
    static void accountTombstoneArchivesAndDrains() {
        // Stamp a Pending Account tombstone directly (as the after-delete trigger
        // would), then prove the shared TombstoneOutboxBatch archives it under the
        // Account config and drains it.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = new Account(Name = 'Tomb', Portal__c = 'TriBU');
        insert a;
        insert new HS_Sync_Tombstone__c(
            SObject_Name__c = 'Account', Record_Id__c = a.Id,
            Status__c = PortalSyncConfig.STATUS_PENDING, Retry_Count__c = 0
        );
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'archived Account tombstone should be deleted');
    }

    @isTest
    static void accountTriggerStampsPendingOnInsert() {
        Account a = new Account(Name = 'New Co', Portal__c = 'TriBU');
        insert a;
        Account after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
                         FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'every new Account should be stamped Pending by the before-insert trigger');
        System.assertEquals(false, after.HS_Portal_Changed__c, 'no portal move on create');
        System.assertEquals(0, after.HS_Retry_Count__c);
    }

    @isTest
    static void accountReconciliationRuns() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        insert new Account(Name = 'Rec Co', Portal__c = 'TriBU');
        Test.startTest();
        Database.executeBatch(new PortalSyncReconciliationBatch('Account', 30), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void accountDeleteWritesAndDrainsTombstone() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Account a = new Account(Name = 'Del Co', Portal__c = 'Berger-Levrault Spain');
        insert a;
        delete a; // after-delete trigger writes a tombstone tagged Account
        System.assertEquals(1, [SELECT COUNT() FROM HS_Sync_Tombstone__c WHERE SObject_Name__c = 'Account']);
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'tombstone removed after successful archive');
    }

    @isTest
    static void accountUndeleteRestamps() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Account a = new Account(Name = 'Undel Co', Portal__c = 'Berger-Levrault Spain');
        insert a;
        delete a;
        Test.startTest();
        undelete a;
        Test.stopTest();
        Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c);
    }

    // ---- Opportunity: the generic engine driving a third object -------------
    // Same outbox/router/handler code syncing Opportunity via its
    // Portal_Sync_Object__mdt config (HubSpot deals, deal_id_sf). Opportunity is
    // a standard object requiring Name/StageName/CloseDate on insert.

    private static Opportunity makePendingOpp(String portal, Boolean portalChanged) {
        Opportunity o = new Opportunity(
            Name = 'Deal ' + Math.round(Math.random()*100000),
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = portal
        );
        insert o;
        // Pin the exact status + portalChanged flag this test needs (the trigger
        // stamps Pending on insert with portalChanged=false).
        o.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
        o.HS_Portal_Changed__c = portalChanged;
        update o;
        return o;
    }

    @isTest
    static void opportunityOutboxSyncsPending() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Opportunity o = makePendingOpp('TriBU', false);
        Test.startTest();
        Database.executeBatch(new OpportunityOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Opportunity after = [SELECT HS_Sync_Status__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void opportunityPortalMoveArchivesOthers() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Opportunity o = makePendingOpp('TriBU', true); // portal changed -> archive others
        Test.startTest();
        Database.executeBatch(new OpportunityOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Opportunity after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(false, after.HS_Portal_Changed__c, 'flag cleared after sync');
    }

    @isTest
    static void opportunityArchivesInNoPortal() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true; // force batch/read to resolve a deal id to archive
        Test.setMock(HttpCalloutMock.class, mock);
        Opportunity o = makePendingOpp('', false); // blank Portal__c -> selectedPortals empty
        Test.startTest();
        Database.executeBatch(new OpportunityOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Opportunity after = [SELECT HS_Sync_Status__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void opportunityFailedUpsertDeadLetters() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.failBatch = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Opportunity o = makePendingOpp('TriBU', false);
        Test.startTest();
        Database.executeBatch(new OpportunityOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Opportunity after = [SELECT HS_Sync_Status__c, HS_Retry_Count__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_FAILED, after.HS_Sync_Status__c);
        System.assertEquals(1, after.HS_Retry_Count__c, 'retry incremented on failure');
        List<PortalSyncDeadLetter__c> dead = [SELECT SObject_Name__c FROM PortalSyncDeadLetter__c];
        System.assertEquals(1, dead.size(), 'a failed Opportunity upsert should buffer a dead-letter row');
        System.assertEquals('Opportunity', dead[0].SObject_Name__c, 'dead letter should be tagged with the object');
    }

    @isTest
    static void opportunityTombstoneArchivesAndDrains() {
        // Stamp a Pending Opportunity tombstone directly (as the after-delete
        // trigger would), then prove the shared TombstoneOutboxBatch archives it
        // under the Opportunity config and drains it.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Opportunity o = new Opportunity(
            Name = 'Tomb', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU'
        );
        insert o;
        insert new HS_Sync_Tombstone__c(
            SObject_Name__c = 'Opportunity', Record_Id__c = o.Id,
            Status__c = PortalSyncConfig.STATUS_PENDING, Retry_Count__c = 0
        );
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'archived Opportunity tombstone should be deleted');
    }

    @isTest
    static void opportunityTriggerStampsPendingOnInsert() {
        Opportunity o = new Opportunity(
            Name = 'New Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU'
        );
        insert o;
        Opportunity after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
                             FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'every new Opportunity should be stamped Pending by the before-insert trigger');
        System.assertEquals(false, after.HS_Portal_Changed__c, 'no portal move on create');
        System.assertEquals(0, after.HS_Retry_Count__c);
    }

    @isTest
    static void opportunityReconciliationRuns() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        insert new Opportunity(
            Name = 'Rec Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU'
        );
        Test.startTest();
        Database.executeBatch(new PortalSyncReconciliationBatch('Opportunity', 30), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void opportunityDeleteWritesAndDrainsTombstone() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Opportunity o = new Opportunity(
            Name = 'Del Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'Berger-Levrault Spain'
        );
        insert o;
        delete o; // after-delete trigger writes a tombstone tagged Opportunity
        System.assertEquals(1, [SELECT COUNT() FROM HS_Sync_Tombstone__c WHERE SObject_Name__c = 'Opportunity']);
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'tombstone removed after successful archive');
    }

    @isTest
    static void opportunityUndeleteRestamps() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Opportunity o = new Opportunity(
            Name = 'Undel Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'Berger-Levrault Spain'
        );
        insert o;
        delete o;
        Test.startTest();
        undelete o;
        Test.stopTest();
        Opportunity after = [SELECT HS_Sync_Status__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c);
    }

    // ---- Asset: the generic engine driving a fourth object ------------------
    // Same outbox/router/handler code syncing Asset via its Portal_Sync_Object__mdt
    // config (HubSpot assets, asset_id_sf). Asset is a standard object requiring
    // Name plus a parent Account/Contact on insert.

    private static Id parentAcctId;
    private static Id parentAccountId() {
        if (parentAcctId == null) {
            Account a = new Account(Name = 'Asset Parent');
            insert a;
            parentAcctId = a.Id;
        }
        return parentAcctId;
    }

    private static Asset makePendingAsset(String portal, Boolean portalChanged) {
        Asset asset = new Asset(
            Name = 'Widget ' + Math.round(Math.random()*100000),
            AccountId = parentAccountId(), Portal__c = portal
        );
        insert asset;
        // Pin the exact status + portalChanged flag this test needs (the trigger
        // stamps Pending on insert with portalChanged=false).
        asset.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
        asset.HS_Portal_Changed__c = portalChanged;
        update asset;
        return asset;
    }

    @isTest
    static void assetOutboxSyncsPending() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Asset asset = makePendingAsset('TriBU', false);
        Test.startTest();
        Database.executeBatch(new AssetOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Asset after = [SELECT HS_Sync_Status__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void assetPortalMoveArchivesOthers() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Asset asset = makePendingAsset('TriBU', true); // portal changed -> archive others
        Test.startTest();
        Database.executeBatch(new AssetOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Asset after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(false, after.HS_Portal_Changed__c, 'flag cleared after sync');
    }

    @isTest
    static void assetArchivesInNoPortal() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true; // force batch/read to resolve an asset id to archive
        Test.setMock(HttpCalloutMock.class, mock);
        Asset asset = makePendingAsset('', false); // blank Portal__c -> selectedPortals empty
        Test.startTest();
        Database.executeBatch(new AssetOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Asset after = [SELECT HS_Sync_Status__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void assetFailedUpsertDeadLetters() {
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.failBatch = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Asset asset = makePendingAsset('TriBU', false);
        Test.startTest();
        Database.executeBatch(new AssetOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Asset after = [SELECT HS_Sync_Status__c, HS_Retry_Count__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_FAILED, after.HS_Sync_Status__c);
        System.assertEquals(1, after.HS_Retry_Count__c, 'retry incremented on failure');
        List<PortalSyncDeadLetter__c> dead = [SELECT SObject_Name__c FROM PortalSyncDeadLetter__c];
        System.assertEquals(1, dead.size(), 'a failed Asset upsert should buffer a dead-letter row');
        System.assertEquals('Asset', dead[0].SObject_Name__c, 'dead letter should be tagged with the object');
    }

    @isTest
    static void assetTombstoneArchivesAndDrains() {
        // Stamp a Pending Asset tombstone directly (as the after-delete trigger
        // would), then prove the shared TombstoneOutboxBatch archives it under the
        // Asset config and drains it.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Asset asset = new Asset(Name = 'Tomb', AccountId = parentAccountId(), Portal__c = 'TriBU');
        insert asset;
        insert new HS_Sync_Tombstone__c(
            SObject_Name__c = 'Asset', Record_Id__c = asset.Id,
            Status__c = PortalSyncConfig.STATUS_PENDING, Retry_Count__c = 0
        );
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'archived Asset tombstone should be deleted');
    }

    @isTest
    static void assetTriggerStampsPendingOnInsert() {
        Asset asset = new Asset(Name = 'New Widget', AccountId = parentAccountId(), Portal__c = 'TriBU');
        insert asset;
        Asset after = [SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
                       FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'every new Asset should be stamped Pending by the before-insert trigger');
        System.assertEquals(false, after.HS_Portal_Changed__c, 'no portal move on create');
        System.assertEquals(0, after.HS_Retry_Count__c);
    }

    @isTest
    static void assetReconciliationRuns() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        insert new Asset(Name = 'Rec Widget', AccountId = parentAccountId(), Portal__c = 'TriBU');
        Test.startTest();
        Database.executeBatch(new PortalSyncReconciliationBatch('Asset', 30), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void assetDeleteWritesAndDrainsTombstone() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Asset asset = new Asset(Name = 'Del Widget', AccountId = parentAccountId(), Portal__c = 'Berger-Levrault Spain');
        insert asset;
        delete asset; // after-delete trigger writes a tombstone tagged Asset
        System.assertEquals(1, [SELECT COUNT() FROM HS_Sync_Tombstone__c WHERE SObject_Name__c = 'Asset']);
        Test.startTest();
        Database.executeBatch(new TombstoneOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM HS_Sync_Tombstone__c],
            'tombstone removed after successful archive');
    }

    @isTest
    static void assetUndeleteRestamps() {
        Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
        Asset asset = new Asset(Name = 'Undel Widget', AccountId = parentAccountId(), Portal__c = 'Berger-Levrault Spain');
        insert asset;
        delete asset;
        Test.startTest();
        undelete asset;
        Test.stopTest();
        Asset after = [SELECT HS_Sync_Status__c FROM Asset WHERE Id = :asset.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c);
    }

    // ---- Associations: Contact->Account (Lookup) & Contact->Deal (Junction) --
    // The Contact outbox reasserts HubSpot associations after the field upserts.
    // returnExisting makes the object batch/read resolve both ends to HubSpot ids;
    // the association endpoints are handled separately by the mock.

    private static Account makeAccountFor(String portal) {
        Account a = new Account(Name = 'Assoc Co ' + Math.round(Math.random()*100000), Portal__c = portal);
        insert a;
        return a;
    }

    private static Contact makePendingContactWithAccount(String portal, Id accountId) {
        Contact c = new Contact(LastName = 'Assoc', Portal__c = portal, AccountId = accountId);
        insert c;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_PENDING;
        c.HS_Portal_Changed__c = false;
        update c;
        return c;
    }

    @isTest
    static void associationCreatesContactToAccount() {
        // Contact with an AccountId, both resolvable in HubSpot, no existing link
        // -> the outbox creates the Contact->Account association. No dead letters,
        // and the field sync still lands the Contact Synced.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true; // resolve both ends to HubSpot ids
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = makeAccountFor('TriBU');
        Contact c = makePendingContactWithAccount('TriBU', a.Id);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c],
            'a clean association create should not dead-letter');
    }

    @isTest
    static void associationCreatesContactToDealViaJunction() {
        // OpportunityContactRole is the Contact->Deal junction. A role links the
        // contact to the deal; the outbox resolves both and creates the association.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Opportunity o = new Opportunity(
            Name = 'Assoc Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU');
        insert o;
        Contact c = new Contact(LastName = 'DealAssoc', Portal__c = 'TriBU');
        insert c; // stamped Pending by trigger
        insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }

    @isTest
    static void associationArchivesStaleLink() {
        // Contact relates to no other record, but HubSpot reports an existing link
        // -> the diff archives it. returnExistingAssociations drives the stale link.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        mock.returnExistingAssociations = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Contact c = makePending('TriBU', false); // no AccountId, no OCR
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c],
            'archiving a stale link should succeed cleanly');
    }

    @isTest
    static void associationFailureDeadLettersButRecordStaysSynced() {
        // Association endpoints fail while the object upsert succeeds: the Contact
        // still lands Synced, and the failed link is dead-lettered as ASSOCIATE.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        mock.failAssociations = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = makeAccountFor('TriBU');
        Contact c = makePendingContactWithAccount('TriBU', a.Id);
        Test.startTest();
        Database.executeBatch(new ContactOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_SYNCED, after.HS_Sync_Status__c,
            'an association failure must not fail the record whose fields synced');
        System.assertEquals(1, [SELECT COUNT() FROM PortalSyncDeadLetter__c WHERE Operation__c = 'ASSOCIATE'],
            'the failed association create should be dead-lettered');
    }

    @isTest
    static void ocrTriggerReStampsContactPending() {
        // Adding an OpportunityContactRole must re-stamp the related Contact Pending
        // so the next outbox reasserts its deal associations, even though no mapped
        // Contact field changed.
        Contact c = new Contact(LastName = 'OcrStamp', Portal__c = 'TriBU');
        insert c;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED; // reach terminal state
        update c;
        Opportunity o = new Opportunity(
            Name = 'OcrDeal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU');
        insert o;
        Test.startTest();
        insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id);
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'a new OpportunityContactRole should re-stamp its Contact Pending');
    }

    @isTest
    static void ocrDeleteReStampsContactPending() {
        Contact c = new Contact(LastName = 'OcrDel', Portal__c = 'TriBU');
        insert c;
        Opportunity o = new Opportunity(
            Name = 'OcrDelDeal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Portal__c = 'TriBU');
        insert o;
        OpportunityContactRole ocr = new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id);
        insert ocr;
        c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED; // reach terminal state
        update c;
        Test.startTest();
        delete ocr;
        Test.stopTest();
        Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(PortalSyncConfig.STATUS_PENDING, after.HS_Sync_Status__c,
            'removing an OpportunityContactRole should re-stamp its Contact Pending');
    }

    @isTest
    static void reconciliationReassertsAssociations() {
        // The nightly reconciliation batch also runs the association diff.
        HubSpotCalloutMock mock = new HubSpotCalloutMock();
        mock.returnExisting = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Account a = makeAccountFor('TriBU');
        insert new Contact(LastName = 'RecAssoc', Portal__c = 'TriBU', AccountId = a.Id);
        Test.startTest();
        Database.executeBatch(new PortalSyncReconciliationBatch('Contact', 30), PortalSyncConfig.BATCH_SCOPE);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    }
}
