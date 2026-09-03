/**
 * Launches the inbound (HubSpot -> Salesforce) polls, one per configured object,
 * plus the shared sf-id write-back drain.
 *
 * Separate from PortalSyncScheduler so the two directions can run on offset
 * crons and neither is coupled to the other's cadence. Schedule it 7 minutes
 * away from the outbox so the two rarely contend at all (the overlap guard makes
 * contention safe, but not free -- a skipped run waits a whole cycle):
 *
 *   System.schedule('HS Inbound :07', '0 7  * * * ?', new PortalInboundScheduler());
 *   System.schedule('HS Inbound :22', '0 22 * * * ?', new PortalInboundScheduler());
 *   System.schedule('HS Inbound :37', '0 37 * * * ?', new PortalInboundScheduler());
 *   System.schedule('HS Inbound :52', '0 52 * * * ?', new PortalInboundScheduler());
 *
 * The whole schedule is inert while Inbound_Active__c is unchecked, so it can be
 * deployed and scheduled well ahead of go-live.
 *
 * It also SEEDS the cursor rows the batch iterates. Doing it here rather than in
 * the batch is deliberate: a batch's start() cannot perform DML, and the
 * scheduler makes no callouts, so this is the one place the rows can be created
 * safely. It also means the rows exist -- and are visible and pausable in the UI
 * -- from the first scheduled run, before any polling happens.
 */
public with sharing class PortalInboundScheduler implements Schedulable {
  public void execute(SchedulableContext sc) {
    List<PortalSyncConfig.ObjectConfig> objects = PortalSyncConfig.inboundObjects();

    // DML first, and only DML: nothing here calls out, so there is no
    // callout-first constraint to honour in this transaction.
    ensureCursors(objects);

    for (PortalSyncConfig.ObjectConfig cfg : objects) {
      // Mutual guard: skip while EITHER direction is running for this
      // object. Without the outbound half, the outbox's status write can
      // land after an inbound Pending stamp and silently drop the
      // inbound-won value's fan-out until the nightly reconciliation.
      if (PortalSyncJobs.isAnyRunning(PortalSyncJobs.bothDirections(cfg)))
        continue;

      Type batchType = Type.forName(cfg.inboundBatchClass);
      if (batchType == null) {
        PortalSyncDeadLetter.log(
          cfg.sObjectName,
          'INBOUND_CONFIG',
          null,
          'INBOUND_CURSOR',
          'Inbound_Batch_Class__c names "' +
            cfg.inboundBatchClass +
            '", which is not a resolvable Apex class -- inbound skipped for this object'
        );
        continue;
      }
      // Scope 1: one cursor row -- i.e. one portal -- per execute(), so
      // each portal gets its own callout, DML and heap budget.
      Database.executeBatch(
        (Database.Batchable<SObject>) batchType.newInstance(),
        1
      );
    }

    if (!PortalSyncJobs.isRunning('PortalInboundStampBatch')) {
      Database.executeBatch(
        new PortalInboundStampBatch(),
        PortalSyncConfig.BATCH_SCOPE
      );
    }
    PortalSyncDeadLetter.flush();
  }

  /**
   * Create any missing (object, portal) cursor row, for every portal that
   * actually has inbound fields configured. Upserted on the Cursor_Key__c
   * external id, so this is idempotent and cannot produce a duplicate row even
   * if two schedulers overlap.
   *
   * Only the identity fields are populated, which matters: an upsert writes
   * only the fields present on the sObject, so re-running this never disturbs
   * an existing row's Watermark__c or Paused__c.
   */
  @TestVisible
  private static void ensureCursors(
    List<PortalSyncConfig.ObjectConfig> objects
  ) {
    List<HS_Inbound_Cursor__c> seeds = new List<HS_Inbound_Cursor__c>();
    for (PortalSyncConfig.ObjectConfig cfg : objects) {
      for (String portal : PortalSyncConfig.allPortalValues()) {
        // A portal with no HubSpot-owned field on this object is not
        // polled and needs no cursor.
        if (
          PortalSyncConfig.inboundFieldMapFor(cfg.sObjectName, portal).isEmpty()
        )
          continue;
        seeds.add(
          new HS_Inbound_Cursor__c(
            Cursor_Key__c = cursorKey(cfg.sObjectName, portal),
            SObject_Name__c = cfg.sObjectName,
            Portal__c = portal
          )
        );
      }
    }
    if (seeds.isEmpty())
      return;
    Database.upsert(seeds, HS_Inbound_Cursor__c.Cursor_Key__c, false);
  }

  /** The cursor row's external id. Kept here so the batch, the scheduler and
   *  the tests all derive it the same way. */
  public static String cursorKey(String sObjectName, String portal) {
    return sObjectName + '|' + portal;
  }
}
