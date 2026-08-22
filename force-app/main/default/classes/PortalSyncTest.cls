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
      LastName = 'T',
      Email = 't' + Math.round(Math.random() * 100000) + '@ex.com',
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
  private static List<Contact> makePendingBulk(
    Integer n,
    String portal,
    Boolean portalChanged
  ) {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < n; i++) {
      contacts.add(
        new Contact(
          LastName = 'B' + i,
          Email = 'b' + i + '@ex.com',
          Portal__c = portal
        )
      );
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
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Contact
        WHERE HS_Sync_Status__c != :PortalSyncConfig.STATUS_SYNCED
      ],
      'every contact in a bulk change should end Synced'
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [
      SELECT HS_Sync_Status__c, HS_Retry_Count__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      1,
      after.HS_Retry_Count__c,
      'retry incremented on failure'
    );
    List<PortalSyncDeadLetter__c> dead = [
      SELECT Error__c
      FROM PortalSyncDeadLetter__c
    ];
    System.assertEquals(
      1,
      dead.size(),
      'a failed batch upsert should buffer a dead-letter row'
    );
    System.assert(
      dead[0].Error__c.contains('HTTP 500'),
      'dead letter should carry the real HubSpot status, got: ' +
      dead[0].Error__c
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    // If the exception had aborted execute(), status updates never run and the
    // rows would still be Pending. They are Failed -> the run completed.
    System.assertEquals(
      3,
      [
        SELECT COUNT()
        FROM Contact
        WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_FAILED
      ]
    );
    System.assertEquals(3, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
    PortalSyncDeadLetter__c d = [
      SELECT Error__c
      FROM PortalSyncDeadLetter__c
      LIMIT 1
    ];
    System.assert(
      d.Error__c.contains('Callout error'),
      'the callout exception should be captured: ' + d.Error__c
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Contact
        WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_FAILED
      ],
      'only the record HubSpot rejected should be Failed'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Contact
        WHERE HS_Sync_Status__c = :PortalSyncConfig.STATUS_SYNCED
      ]
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  // Stamp a Pending tombstone directly, the way the after-delete trigger would,
  // so the batch is exercised without depending on the org's delete automation.
  private static HS_Sync_Tombstone__c makeTombstone() {
    Contact c = new Contact(LastName = 'Tomb', Portal__c = 'TriBU');
    insert c;
    HS_Sync_Tombstone__c t = new HS_Sync_Tombstone__c(
      SObject_Name__c = 'Contact',
      Record_Id__c = c.Id,
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
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
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'archived tombstone should be deleted'
    );
  }

  @isTest
  static void tombstoneFailureRetries() {
    // Batch archive fails -> tombstone kept and marked Failed with retry bump.
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failBatch = true;
    Test.setMock(HttpCalloutMock.class, mock);
    makeTombstone();
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    List<HS_Sync_Tombstone__c> after = [
      SELECT Status__c, Retry_Count__c
      FROM HS_Sync_Tombstone__c
    ];
    System.assertEquals(
      1,
      after.size(),
      'failed archive keeps the tombstone for retry'
    );
    System.assertEquals(PortalSyncConfig.STATUS_FAILED, after[0].Status__c);
    System.assertEquals(1, after[0].Retry_Count__c);
  }

  @isTest
  static void outboxSyncsPendingContact() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Contact c = makePending('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void portalMoveArchivesOthers() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Contact c = makePending('TriBU', true); // portal changed -> archive others
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'flag cleared after sync'
    );
  }

  @isTest
  static void multiselectSyncsEnabledPortalsOnly() {
    // Portal__c is a multiselect: value arrives semicolon-delimited. Include
    // a disabled portal (Carl Software) to prove it is ignored, not archive-everywhere.
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Contact c = makePending('TriBU;Carl Software', true);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'multiselect value should upsert to the enabled portal, not fall into archive-everywhere'
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void deleteWritesAndDrainsTombstone() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Contact c = new Contact(
      LastName = 'Del',
      Portal__c = 'Berger-Levrault Spain'
    );
    insert c;
    delete c; // after-delete trigger writes a tombstone
    System.assertEquals(1, [SELECT COUNT() FROM HS_Sync_Tombstone__c]);
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'tombstone removed after successful archive'
    );
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
    Database.executeBatch(
      new PortalSyncReconciliationBatch(30),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void triggerStampsPendingOnInsert() {
    Contact c = new Contact(LastName = 'New', Portal__c = 'TriBU');
    insert c;
    Contact after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'every new contact should be stamped Pending by the before-insert trigger'
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'no portal move on create'
    );
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
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'changing a mapped field should re-stamp Pending'
    );
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
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'a status-only write-back must not re-stamp Pending'
    );
  }

  @isTest
  static void triggerStampsPortalMove() {
    Contact c = new Contact(LastName = 'Move', Portal__c = 'TriBU');
    insert c;
    c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED;
    update c;
    c.Portal__c = 'Berger-Levrault Spain'; // a real portal move
    update c;
    Contact after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'a portal move should re-stamp Pending'
    );
    System.assertEquals(
      true,
      after.HS_Portal_Changed__c,
      'a portal move should set HS_Portal_Changed__c so the batch archives the old portal'
    );
  }

  @isTest
  static void undeleteRestamps() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Contact c = new Contact(
      LastName = 'Undel',
      Portal__c = 'Berger-Levrault Spain'
    );
    insert c;
    delete c;
    Test.startTest();
    undelete c;
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c
    );
  }

  // ---- Account: the generic engine driving a second object ----------------
  // These prove the same outbox/router/handler code syncs Account via its
  // Portal_Sync_Object__mdt config (HubSpot companies, account_id_sf), with no
  // Contact-specific assumptions leaking in.

  private static Account makePendingAccount(
    String portal,
    Boolean portalChanged
  ) {
    Account a = new Account(
      Name = 'Acme ' + Math.round(Math.random() * 100000),
      Portal__c = portal
    );
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
    Database.executeBatch(
      new AccountOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void accountPortalMoveArchivesOthers() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Account a = makePendingAccount('TriBU', true); // portal changed -> archive others
    Test.startTest();
    Database.executeBatch(
      new AccountOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Account after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c
      FROM Account
      WHERE Id = :a.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'flag cleared after sync'
    );
  }

  @isTest
  static void accountArchivesInNoPortal() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.returnExisting = true; // force batch/read to resolve a company id to archive
    Test.setMock(HttpCalloutMock.class, mock);
    Account a = makePendingAccount('', false); // blank Portal__c -> selectedPortals empty
    Test.startTest();
    Database.executeBatch(
      new AccountOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void accountFailedUpsertDeadLetters() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failBatch = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Account a = makePendingAccount('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new AccountOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Account after = [
      SELECT HS_Sync_Status__c, HS_Retry_Count__c
      FROM Account
      WHERE Id = :a.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      1,
      after.HS_Retry_Count__c,
      'retry incremented on failure'
    );
    List<PortalSyncDeadLetter__c> dead = [
      SELECT SObject_Name__c
      FROM PortalSyncDeadLetter__c
    ];
    System.assertEquals(
      1,
      dead.size(),
      'a failed Account upsert should buffer a dead-letter row'
    );
    System.assertEquals(
      'Account',
      dead[0].SObject_Name__c,
      'dead letter should be tagged with the object'
    );
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
      SObject_Name__c = 'Account',
      Record_Id__c = a.Id,
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'archived Account tombstone should be deleted'
    );
  }

  @isTest
  static void accountTriggerStampsPendingOnInsert() {
    Account a = new Account(Name = 'New Co', Portal__c = 'TriBU');
    insert a;
    Account after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
      FROM Account
      WHERE Id = :a.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'every new Account should be stamped Pending by the before-insert trigger'
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'no portal move on create'
    );
    System.assertEquals(0, after.HS_Retry_Count__c);
  }

  @isTest
  static void accountReconciliationRuns() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    insert new Account(Name = 'Rec Co', Portal__c = 'TriBU');
    Test.startTest();
    Database.executeBatch(
      new PortalSyncReconciliationBatch('Account', 30),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void accountDeleteWritesAndDrainsTombstone() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Account a = new Account(
      Name = 'Del Co',
      Portal__c = 'Berger-Levrault Spain'
    );
    insert a;
    delete a; // after-delete trigger writes a tombstone tagged Account
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM HS_Sync_Tombstone__c
        WHERE SObject_Name__c = 'Account'
      ]
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'tombstone removed after successful archive'
    );
  }

  @isTest
  static void accountUndeleteRestamps() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Account a = new Account(
      Name = 'Undel Co',
      Portal__c = 'Berger-Levrault Spain'
    );
    insert a;
    delete a;
    Test.startTest();
    undelete a;
    Test.stopTest();
    Account after = [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c
    );
  }

  // ---- Opportunity: the generic engine driving a third object -------------
  // Same outbox/router/handler code syncing Opportunity via its
  // Portal_Sync_Object__mdt config (HubSpot deals, deal_id_sf). Opportunity is
  // a standard object requiring Name/StageName/CloseDate on insert.

  private static Opportunity makePendingOpp(
    String portal,
    Boolean portalChanged
  ) {
    Opportunity o = new Opportunity(
      Name = 'Deal ' + Math.round(Math.random() * 100000),
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
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
    Database.executeBatch(
      new OpportunityOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Opportunity after = [
      SELECT HS_Sync_Status__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void opportunityPortalMoveArchivesOthers() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Opportunity o = makePendingOpp('TriBU', true); // portal changed -> archive others
    Test.startTest();
    Database.executeBatch(
      new OpportunityOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Opportunity after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'flag cleared after sync'
    );
  }

  @isTest
  static void opportunityArchivesInNoPortal() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.returnExisting = true; // force batch/read to resolve a deal id to archive
    Test.setMock(HttpCalloutMock.class, mock);
    Opportunity o = makePendingOpp('', false); // blank Portal__c -> selectedPortals empty
    Test.startTest();
    Database.executeBatch(
      new OpportunityOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Opportunity after = [
      SELECT HS_Sync_Status__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void opportunityFailedUpsertDeadLetters() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failBatch = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Opportunity o = makePendingOpp('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new OpportunityOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Opportunity after = [
      SELECT HS_Sync_Status__c, HS_Retry_Count__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      1,
      after.HS_Retry_Count__c,
      'retry incremented on failure'
    );
    List<PortalSyncDeadLetter__c> dead = [
      SELECT SObject_Name__c
      FROM PortalSyncDeadLetter__c
    ];
    System.assertEquals(
      1,
      dead.size(),
      'a failed Opportunity upsert should buffer a dead-letter row'
    );
    System.assertEquals(
      'Opportunity',
      dead[0].SObject_Name__c,
      'dead letter should be tagged with the object'
    );
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
      Name = 'Tomb',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    insert o;
    insert new HS_Sync_Tombstone__c(
      SObject_Name__c = 'Opportunity',
      Record_Id__c = o.Id,
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'archived Opportunity tombstone should be deleted'
    );
  }

  @isTest
  static void opportunityTriggerStampsPendingOnInsert() {
    Opportunity o = new Opportunity(
      Name = 'New Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    insert o;
    Opportunity after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'every new Opportunity should be stamped Pending by the before-insert trigger'
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'no portal move on create'
    );
    System.assertEquals(0, after.HS_Retry_Count__c);
  }

  @isTest
  static void opportunityReconciliationRuns() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    insert new Opportunity(
      Name = 'Rec Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    Test.startTest();
    Database.executeBatch(
      new PortalSyncReconciliationBatch('Opportunity', 30),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void opportunityDeleteWritesAndDrainsTombstone() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Opportunity o = new Opportunity(
      Name = 'Del Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'Berger-Levrault Spain'
    );
    insert o;
    delete o; // after-delete trigger writes a tombstone tagged Opportunity
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM HS_Sync_Tombstone__c
        WHERE SObject_Name__c = 'Opportunity'
      ]
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'tombstone removed after successful archive'
    );
  }

  @isTest
  static void opportunityUndeleteRestamps() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Opportunity o = new Opportunity(
      Name = 'Undel Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'Berger-Levrault Spain'
    );
    insert o;
    delete o;
    Test.startTest();
    undelete o;
    Test.stopTest();
    Opportunity after = [
      SELECT HS_Sync_Status__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c
    );
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
      Name = 'Widget ' + Math.round(Math.random() * 100000),
      AccountId = parentAccountId(),
      Portal__c = portal
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
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void assetPortalMoveArchivesOthers() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Asset asset = makePendingAsset('TriBU', true); // portal changed -> archive others
    Test.startTest();
    Database.executeBatch(new AssetOutboxBatch(), PortalSyncConfig.BATCH_SCOPE);
    Test.stopTest();
    Asset after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c
      FROM Asset
      WHERE Id = :asset.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'flag cleared after sync'
    );
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
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
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
    Asset after = [
      SELECT HS_Sync_Status__c, HS_Retry_Count__c
      FROM Asset
      WHERE Id = :asset.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      1,
      after.HS_Retry_Count__c,
      'retry incremented on failure'
    );
    List<PortalSyncDeadLetter__c> dead = [
      SELECT SObject_Name__c
      FROM PortalSyncDeadLetter__c
    ];
    System.assertEquals(
      1,
      dead.size(),
      'a failed Asset upsert should buffer a dead-letter row'
    );
    System.assertEquals(
      'Asset',
      dead[0].SObject_Name__c,
      'dead letter should be tagged with the object'
    );
  }

  @isTest
  static void assetTombstoneArchivesAndDrains() {
    // Stamp a Pending Asset tombstone directly (as the after-delete trigger
    // would), then prove the shared TombstoneOutboxBatch archives it under the
    // Asset config and drains it.
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.returnExisting = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Asset asset = new Asset(
      Name = 'Tomb',
      AccountId = parentAccountId(),
      Portal__c = 'TriBU'
    );
    insert asset;
    insert new HS_Sync_Tombstone__c(
      SObject_Name__c = 'Asset',
      Record_Id__c = asset.Id,
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'archived Asset tombstone should be deleted'
    );
  }

  @isTest
  static void assetTriggerStampsPendingOnInsert() {
    Asset asset = new Asset(
      Name = 'New Widget',
      AccountId = parentAccountId(),
      Portal__c = 'TriBU'
    );
    insert asset;
    Asset after = [
      SELECT HS_Sync_Status__c, HS_Portal_Changed__c, HS_Retry_Count__c
      FROM Asset
      WHERE Id = :asset.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'every new Asset should be stamped Pending by the before-insert trigger'
    );
    System.assertEquals(
      false,
      after.HS_Portal_Changed__c,
      'no portal move on create'
    );
    System.assertEquals(0, after.HS_Retry_Count__c);
  }

  @isTest
  static void assetReconciliationRuns() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    insert new Asset(
      Name = 'Rec Widget',
      AccountId = parentAccountId(),
      Portal__c = 'TriBU'
    );
    Test.startTest();
    Database.executeBatch(
      new PortalSyncReconciliationBatch('Asset', 30),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void assetDeleteWritesAndDrainsTombstone() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Asset asset = new Asset(
      Name = 'Del Widget',
      AccountId = parentAccountId(),
      Portal__c = 'Berger-Levrault Spain'
    );
    insert asset;
    delete asset; // after-delete trigger writes a tombstone tagged Asset
    System.assertEquals(
      1,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c WHERE SObject_Name__c = 'Asset']
    );
    Test.startTest();
    Database.executeBatch(
      new TombstoneOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Sync_Tombstone__c],
      'tombstone removed after successful archive'
    );
  }

  @isTest
  static void assetUndeleteRestamps() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Asset asset = new Asset(
      Name = 'Undel Widget',
      AccountId = parentAccountId(),
      Portal__c = 'Berger-Levrault Spain'
    );
    insert asset;
    delete asset;
    Test.startTest();
    undelete asset;
    Test.stopTest();
    Asset after = [SELECT HS_Sync_Status__c FROM Asset WHERE Id = :asset.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c
    );
  }

  // ---- Associations: Contact->Account (Lookup) & Contact->Deal (Junction) --
  // The Contact outbox reasserts HubSpot associations after the field upserts.
  // returnExisting makes the object batch/read resolve both ends to HubSpot ids;
  // the association endpoints are handled separately by the mock.

  private static Account makeAccountFor(String portal) {
    Account a = new Account(
      Name = 'Assoc Co ' + Math.round(Math.random() * 100000),
      Portal__c = portal
    );
    insert a;
    return a;
  }

  private static Contact makePendingContactWithAccount(
    String portal,
    Id accountId
  ) {
    Contact c = new Contact(
      LastName = 'Assoc',
      Portal__c = portal,
      AccountId = accountId
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM PortalSyncDeadLetter__c],
      'a clean association create should not dead-letter'
    );
  }

  @isTest
  static void associationCreatesContactToDealViaJunction() {
    // OpportunityContactRole is the Contact->Deal junction. A role links the
    // contact to the deal; the outbox resolves both and creates the association.
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.returnExisting = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Opportunity o = new Opportunity(
      Name = 'Assoc Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    insert o;
    Contact c = new Contact(LastName = 'DealAssoc', Portal__c = 'TriBU');
    insert c; // stamped Pending by trigger
    insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM PortalSyncDeadLetter__c],
      'archiving a stale link should succeed cleanly'
    );
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
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'an association failure must not fail the record whose fields synced'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'ASSOCIATE'
      ],
      'the failed association create should be dead-lettered'
    );
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
      Name = 'OcrDeal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    insert o;
    Test.startTest();
    insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id);
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'a new OpportunityContactRole should re-stamp its Contact Pending'
    );
  }

  @isTest
  static void ocrDeleteReStampsContactPending() {
    Contact c = new Contact(LastName = 'OcrDel', Portal__c = 'TriBU');
    insert c;
    Opportunity o = new Opportunity(
      Name = 'OcrDelDeal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Portal__c = 'TriBU'
    );
    insert o;
    OpportunityContactRole ocr = new OpportunityContactRole(
      OpportunityId = o.Id,
      ContactId = c.Id
    );
    insert ocr;
    c.HS_Sync_Status__c = PortalSyncConfig.STATUS_SYNCED; // reach terminal state
    update c;
    Test.startTest();
    delete ocr;
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      after.HS_Sync_Status__c,
      'removing an OpportunityContactRole should re-stamp its Contact Pending'
    );
  }

  @isTest
  static void reconciliationReassertsAssociations() {
    // The nightly reconciliation batch also runs the association diff.
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.returnExisting = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Account a = makeAccountFor('TriBU');
    insert new Contact(
      LastName = 'RecAssoc',
      Portal__c = 'TriBU',
      AccountId = a.Id
    );
    Test.startTest();
    Database.executeBatch(
      new PortalSyncReconciliationBatch('Contact', 30),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  // ---- Owner sync: hubspot_owner_id ---------------------------------------
  // Portal_Sync_Object__mdt.Sync_Owner__c (set true for Contact) resolves the
  // record's Owner by email to a HubSpot owner and sends it as
  // hubspot_owner_id alongside the mapped fields on the same upsert payload.

  @isTest
  static void ownerSyncSetsHubspotOwnerIdOnUpsert() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.ownerEmailToMatch = UserInfo.getUserEmail(); // test records default OwnerId to the running user
    Test.setMock(HttpCalloutMock.class, mock);
    Contact c = makePending('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c
    );
    Map<String, Object> props = mock.capturedUpsertProps.get(c.Id);
    System.assertNotEquals(
      null,
      props,
      'the upsert payload for this contact should have been captured'
    );
    System.assertEquals(
      mock.ownerHsId,
      props.get('hubspot_owner_id'),
      'the resolved HubSpot owner id should be sent as hubspot_owner_id'
    );
  }

  @isTest
  static void ownerSyncSkipsPropertyWhenEmailUnresolved() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock(); // ownerEmailToMatch left null -> no match
    Test.setMock(HttpCalloutMock.class, mock);
    Contact c = makePending('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'an unresolved owner must not fail the record'
    );
    Map<String, Object> props = mock.capturedUpsertProps.get(c.Id);
    System.assert(
      !props.containsKey('hubspot_owner_id'),
      'no owner matched -> hubspot_owner_id should be omitted'
    );
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void ownerSyncFailureDoesNotFailRecordButDeadLetters() {
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failOwners = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Contact c = makePending('TriBU', false);
    Test.startTest();
    Database.executeBatch(
      new ContactOutboxBatch(),
      PortalSyncConfig.BATCH_SCOPE
    );
    Test.stopTest();
    Contact after = [SELECT HS_Sync_Status__c FROM Contact WHERE Id = :c.Id];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'an owners-list failure must not fail the record whose fields synced'
    );
    List<PortalSyncDeadLetter__c> dead = [
      SELECT Operation__c
      FROM PortalSyncDeadLetter__c
      WHERE Operation__c = 'OWNER_RESOLVE'
    ];
    System.assertEquals(
      1,
      dead.size(),
      'the failed owners lookup should be dead-lettered once per portal'
    );
  }

  @isTest
  static void handlerStampsPendingOnOwnerChange() {
    // Direct unit test of PortalSyncHandler, not the trigger -- avoids
    // depending on a second active User existing in the org (a real
    // reassignment needs one; this only needs OwnerId to differ in memory).
    PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig(
      'Contact'
    );
    Contact prior = new Contact(
      Id = '003000000000000AAA',
      OwnerId = '005000000000000AAA',
      Portal__c = 'TriBU'
    );
    Contact updated = new Contact(
      Id = '003000000000000AAA',
      OwnerId = '005000000000000BAA',
      Portal__c = 'TriBU'
    );
    Map<Id, SObject> oldMap = new Map<Id, SObject>{ prior.Id => prior };
    PortalSyncHandler.stampForSync(cfg, new List<SObject>{ updated }, oldMap);
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      updated.get('HS_Sync_Status__c'),
      'an owner reassignment should re-stamp Pending when owner sync is active'
    );
  }

  // ---- Per-portal association type ids ------------------------------------
  // HubSpot generates the association type id inside each portal for custom
  // objects and USER_DEFINED labels, so one config row can legitimately carry a
  // different id per portal (Association_Type_Id_TriBU__c / _CARL__c / _Spain__c)
  // layered over the shared Association_Type_Id__c fallback. Direct unit tests of
  // AssociationConfig -- custom metadata rows cannot be created in a test.

  @isTest
  static void associationTypeIdPrefersThePortalOverride() {
    PortalSyncConfig.AssociationConfig a = new PortalSyncConfig.AssociationConfig();
    a.defaultTypeId = 279;
    a.typeIdByPortal.put('TriBU', 12345);
    System.assertEquals(
      12345,
      a.typeIdFor('TriBU'),
      'the portal override wins wherever it is set'
    );
    System.assertEquals(
      279,
      a.typeIdFor('Carl Software'),
      'a portal with no override falls back to the shared id'
    );
  }

  @isTest
  static void associationTypeIdIsNullWhenNeitherIsConfigured() {
    // Null is what makes the router SKIP the portal instead of asserting an
    // association of an unknown type -- a null type id matches every existing
    // type on read, so the diff could archive links this row does not own.
    PortalSyncConfig.AssociationConfig a = new PortalSyncConfig.AssociationConfig();
    for (String portal : PortalSyncConfig.allPortalValues()) {
      System.assertEquals(
        null,
        a.typeIdFor(portal),
        'an unconfigured association must resolve no type id for ' + portal
      );
    }
  }

  @isTest
  static void seededContactAssociationsResolveATypeIdForEveryOptedInPortal() {
    // The Contact rows are HUBSPOT_DEFINED with stable ids in the shared field
    // and no per-portal overrides: proof the fallback still feeds every portal,
    // i.e. adding the override fields did not silently disable them.
    List<PortalSyncConfig.AssociationConfig> assocs = PortalSyncConfig.associationsFrom(
      'Contact'
    );
    System.assert(
      !assocs.isEmpty(),
      'expected the seeded Contact associations to be active'
    );
    for (PortalSyncConfig.AssociationConfig a : assocs) {
      for (String portal : PortalSyncConfig.allPortalValues()) {
        if (!a.syncsTo(portal))
          continue;
        System.assertNotEquals(
          null,
          a.typeIdFor(portal),
          a.fromObject +
            '->' +
            a.toObject +
            ' resolves no type id for ' +
            portal
        );
      }
    }
  }

  // ---- Value maps (Portal_Sync_Value_Map__mdt) -----------------------------
  // A mapped field whose value must be rewritten on the way out -- a Salesforce
  // record type or picklist landing in a HubSpot picklist, which rejects any
  // value that is not a defined option. Custom metadata rows cannot be inserted
  // in a test, so the loaded cache is seeded directly; the row-level fallback
  // logic is unit tested against an in-memory row.

  /** Seed the value-map cache for one (object, field): portal -> (SF value -> HS value). */
  private static void seedValueMap(
    String sObjectName,
    String sfField,
    Map<String, Map<String, String>> byPortal
  ) {
    PortalSyncConfig.setValueMapsForTest(
      new Map<String, Map<String, Map<String, String>>>{
        PortalSyncConfig.valueMapKey(sObjectName, sfField) => byPortal
      }
    );
  }

  /** Same translation in every enabled portal. */
  private static Map<String, Map<String, String>> everyPortal(
    Map<String, String> values
  ) {
    Map<String, Map<String, String>> byPortal = new Map<String, Map<String, String>>();
    for (String portal : PortalSyncConfig.allPortalValues())
      byPortal.put(portal, values);
    return byPortal;
  }

  /** An in-memory contact -- mapProperties only reads fields, so no DML is
   *  needed, and none of these tests may cross into an async context (batch
   *  execution resets statics, which would drop the seeded cache). */
  private static Contact contactWithTitle(String title) {
    return new Contact(
      Id = '003000000000000AAA',
      LastName = 'V',
      Email = 'v@ex.com',
      Title = title
    );
  }

  @isTest
  static void valueMapTranslatesTheValueSentToHubSpot() {
    // Contact.Title -> jobtitle, with a translation table attached: HubSpot
    // must receive the mapped value, never the raw Salesforce one.
    seedValueMap(
      'Contact',
      'Title',
      everyPortal(new Map<String, String>{ 'ceo' => 'chief_executive' })
    );
    // 'CEO' is deliberately cased differently from the seeded key.
    Map<String, Object> props = HubSpotService.mapProperties(
      contactWithTitle('CEO'),
      'Contact',
      'TriBU'
    );
    System.assertEquals(
      'chief_executive',
      props.get('jobtitle'),
      'a mapped value must be translated, and the match is case-insensitive'
    );
    System.assertEquals(
      'v@ex.com',
      props.get('email'),
      'fields with no value map are unaffected'
    );
  }

  @isTest
  static void unmappedValueOmitsThePropertyAndDeadLetters() {
    // An untranslatable value is skipped rather than sent raw: one bad
    // property must not fail a record whose other fields are fine, but it
    // still has to be visible to an admin.
    seedValueMap(
      'Contact',
      'Title',
      everyPortal(new Map<String, String>{ 'ceo' => 'chief_executive' })
    );
    Map<String, Object> props = HubSpotService.mapProperties(
      contactWithTitle('Caretaker'),
      'Contact',
      'TriBU'
    );
    System.assert(
      !props.containsKey('jobtitle'),
      'no translation for this value -> the property should be omitted, not sent raw'
    );
    System.assert(
      props.containsKey('email'),
      'the record\'s other mapped fields should still sync'
    );
    PortalSyncDeadLetter.flush(); // the router flushes after its callouts; here there are none
    List<PortalSyncDeadLetter__c> dead = [
      SELECT Error__c
      FROM PortalSyncDeadLetter__c
      WHERE Operation__c = 'VALUE_MAP'
    ];
    System.assertEquals(
      1,
      dead.size(),
      'the untranslated value should be dead-lettered once'
    );
    System.assert(
      dead[0].Error__c.contains('Caretaker'),
      'the dead letter should name the value that had no row: ' +
      dead[0].Error__c
    );
  }

  @isTest
  static void fieldWithNoValueMapIsSentVerbatim() {
    // Regression guard: value maps are opt-in per field. A field with no rows
    // must keep the original String.valueOf() behaviour.
    Map<String, Object> props = HubSpotService.mapProperties(
      contactWithTitle('Caretaker'),
      'Contact',
      'TriBU'
    );
    System.assertEquals(
      'Caretaker',
      props.get('jobtitle'),
      'an untranslated field must still be sent verbatim'
    );
    PortalSyncDeadLetter.flush();
    System.assertEquals(0, [SELECT COUNT() FROM PortalSyncDeadLetter__c]);
  }

  @isTest
  static void recordTypeIdIsResolvedToItsDeveloperName() {
    // The reason RecordTypeId is special-cased: the raw value is an 18-char id
    // that differs between orgs, so it is resolved to the DeveloperName before
    // the value map is consulted -- that is what an admin can key a row on.
    // Every object has at least the Master record type, so this always runs.
    Schema.RecordTypeInfo master = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName()
      .get('Master');
    System.assertNotEquals(
      null,
      master,
      'every object exposes a Master record type'
    );
    System.assertEquals(
      'Master',
      HubSpotService.normalize(
        'Opportunity',
        'RecordTypeId',
        master.getRecordTypeId()
      ),
      'a record type id must be resolved to its DeveloperName, never sent verbatim'
    );
  }

  @isTest
  static void normalizeLeavesEverythingElseAlone() {
    // Dates are reformatted (below); apart from those and RecordTypeId,
    // nothing is touched.
    System.assertEquals(
      'Acme',
      HubSpotService.normalize('Opportunity', 'Name', 'Acme'),
      'text is passed through untouched'
    );
    System.assertEquals(
      '1500',
      HubSpotService.normalize('Opportunity', 'Amount', 1500),
      'other values keep the original String.valueOf() behaviour'
    );
    // An id the describe does not know (e.g. a record type deleted since the
    // record was last saved) falls back to the raw value rather than throwing.
    // NB 012000000000000AAA is the Master record type's real id -- it resolves.
    System.assertEquals(
      '012000000000999AAA',
      HubSpotService.normalize(
        'Opportunity',
        'RecordTypeId',
        '012000000000999AAA'
      ),
      'an unresolvable record type id must not throw'
    );
  }

  // ---- Date formatting -----------------------------------------------------
  // String.valueOf(Date) renders "2026-08-22 00:00:00" -- a time component a
  // HubSpot date property rejects. And because a 400 on a batch upsert is not a
  // 207, one bad value dead-letters all 100 records in the chunk, not just the
  // offending one. These tests pin the wire format and, above all, that it does
  // not depend on who the job runs as.

  /** A user in a named time zone, for proving the output does not follow it. */
  private static User userInZone(String tzSidKey, String alias) {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    return new User(
      ProfileId = p.Id,
      Alias = alias,
      TimeZoneSidKey = tzSidKey,
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      LastName = 'TZ',
      Email = alias + '@example.com',
      Username = alias + '@' + UserInfo.getOrganizationId() + '.example.invalid'
    );
  }

  @isTest
  static void dateIsSentAsAPlainCalendarDay() {
    System.assertEquals(
      '2026-08-22',
      HubSpotService.normalize(
        'Opportunity',
        'CloseDate',
        Date.newInstance(2026, 8, 22)
      ),
      'a HubSpot date property takes yyyy-MM-dd, never "2026-08-22 00:00:00"'
    );
  }

  @isTest
  static void singleDigitMonthAndDayArePadded() {
    System.assertEquals(
      '2026-01-05',
      HubSpotService.normalize(
        'Opportunity',
        'CloseDate',
        Date.newInstance(2026, 1, 5)
      ),
      'yyyy-MM-dd is fixed width -- "2026-1-5" is not a valid HubSpot date'
    );
  }

  @isTest
  static void dateNeverShiftsAcrossTimeZones() {
    // A Salesforce Date has no time and no zone. New Year's Day is the case
    // that catches any accidental Datetime round-trip: converted west of GMT
    // it becomes 2025-12-31. The batch runs as whoever scheduled it, so a
    // zone-dependent format would sync the same record two different ways.
    Date d = Date.newInstance(2026, 1, 1);
    User tokyo = userInZone('Asia/Tokyo', 'dzjp');
    User la = userInZone('America/Los_Angeles', 'dzus');
    insert new List<User>{ tokyo, la }; // the only DML here -> no MIXED_DML

    System.runAs(tokyo) {
      System.assertEquals(
        '2026-01-01',
        HubSpotService.normalize('Opportunity', 'CloseDate', d),
        'the calendar day must not follow the running user\'s time zone'
      );
    }
    System.runAs(la) {
      System.assertEquals(
        '2026-01-01',
        HubSpotService.normalize('Opportunity', 'CloseDate', d),
        'the same Date must serialize identically for every running user'
      );
    }
  }

  @isTest
  static void dateFormattingDoesNotDependOnAFieldDescribe() {
    // Formatting keys off the VALUE's type, not a describe of the configured
    // field name -- so a misspelled field or an unknown object cannot silently
    // fall back to the rejected "2026-08-22 00:00:00" shape.
    System.assertEquals(
      '2026-08-22',
      HubSpotService.normalize(
        'No_Such_Object__c',
        'Not_A_Field__c',
        Date.newInstance(2026, 8, 22)
      ),
      'an unresolvable object/field must still format the date correctly'
    );
  }

  @isTest
  static void aDateIsFormattedBeforeTheValueMapIsConsulted() {
    // normalize() runs before the value-map lookup, like RecordTypeId, so a
    // value map on a date field keys on what actually goes on the wire.
    // Regression guard for anyone who moves the formatting later.
    seedValueMap(
      'Contact',
      'Birthdate',
      everyPortal(new Map<String, String>{ '2026-08-22' => 'FY26_Q3' })
    );
    System.assertEquals(
      'FY26_Q3',
      PortalSyncConfig.translateValue(
        'Contact',
        'Birthdate',
        'TriBU',
        HubSpotService.normalize(
          'Contact',
          'Birthdate',
          Date.newInstance(2026, 8, 22)
        )
      ),
      'the value map keys on the formatted value, not the raw String.valueOf() one'
    );
  }

  @isTest
  static void valueMapPortalOverrideWinsOverTheSharedValue() {
    // A HubSpot picklist option's internal value is defined per portal, so the
    // same Salesforce value can legitimately need a different value per portal.
    Portal_Sync_Value_Map__mdt row = new Portal_Sync_Value_Map__mdt(
      Salesforce_Value__c = 'Renewal_Business',
      HubSpot_Value__c = 'renewal',
      HubSpot_Value_TriBU__c = 'renewal_business'
    );
    System.assertEquals(
      'renewal_business',
      PortalSyncConfig.portalValueOf(row, 'TriBU'),
      'the portal override wins wherever it is set'
    );
    System.assertEquals(
      'renewal',
      PortalSyncConfig.portalValueOf(row, 'Carl Software'),
      'a portal with no override falls back to the shared value'
    );
  }

  @isTest
  static void translateValueIsNullForAnythingUnconfigured() {
    // Null is what makes mapProperties OMIT the property instead of guessing.
    seedValueMap(
      'Contact',
      'Title',
      everyPortal(new Map<String, String>{ 'ceo' => 'chief_executive' })
    );
    System.assert(PortalSyncConfig.hasValueMap('Contact', 'Title'));
    System.assert(
      !PortalSyncConfig.hasValueMap('Contact', 'Email'),
      'a field with no rows must not be treated as translated'
    );
    System.assertEquals(
      null,
      PortalSyncConfig.translateValue('Contact', 'Title', 'TriBU', 'Caretaker'),
      'an unmapped value resolves to null'
    );
    System.assertEquals(
      null,
      PortalSyncConfig.translateValue('Contact', 'Title', 'TriBU', null),
      'a null value resolves to null'
    );
    System.assertEquals(
      null,
      PortalSyncConfig.translateValue('Contact', 'Email', 'TriBU', 'ceo'),
      'an untranslated field resolves to null'
    );
  }
}
