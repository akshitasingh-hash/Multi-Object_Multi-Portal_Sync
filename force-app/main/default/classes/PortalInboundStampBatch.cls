/**
 * Writes the Salesforce id of an inbound-CREATED record back onto the HubSpot
 * record it came from, then releases that record into the outbox.
 *
 * Why this is a separate, durable job rather than something the inbound batch
 * finishes itself: the Salesforce id only exists after the insert, and Apex
 * forbids a callout after uncommitted DML, so the write-back cannot happen in
 * the same transaction. Staging it in HS_Inbound_Stamp__c rather than a
 * Queueable is what makes it survivable -- if the pairing of (HubSpot id ->
 * Salesforce id) were ever lost, the HubSpot record would keep a blank sf-id
 * property and the next poll would import it AGAIN as a second Salesforce
 * record. That duplicate is the worst failure mode in the inbound design, so
 * the queue is durable and rows are never dropped except on success.
 *
 * One class for every object, like TombstoneOutboxBatch: grouped by (object,
 * portal) inside execute(), so it needs no per-object subclass.
 *
 * Callout-first / DML-last, like every other batch here.
 */
public with sharing class PortalInboundStampBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
  public Database.QueryLocator start(Database.BatchableContext bc) {
    String pending = PortalSyncConfig.STATUS_PENDING;
    String failed = PortalSyncConfig.STATUS_FAILED;
    Integer maxRetries = PortalSyncConfig.MAX_RETRIES;
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          Record_Id__c,
          HubSpot_Id__c,
          Portal__c,
          SObject_Name__c,
          Status__c,
          Retry_Count__c
        FROM HS_Inbound_Stamp__c
        WHERE
          Status__c = :pending
          OR (Status__c = :failed
          AND Retry_Count__c < :maxRetries)
      ]
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<HS_Inbound_Stamp__c> scope
  ) {
    // (object|portal) -> hsId -> sfId, so each group is one batch callout.
    Map<String, Map<String, String>> byGroup = new Map<String, Map<String, String>>();
    Map<String, List<HS_Inbound_Stamp__c>> rowsByGroup = new Map<String, List<HS_Inbound_Stamp__c>>();

    for (HS_Inbound_Stamp__c row : scope) {
      String groupKey = row.SObject_Name__c + '|' + row.Portal__c;
      if (!byGroup.containsKey(groupKey)) {
        byGroup.put(groupKey, new Map<String, String>());
        rowsByGroup.put(groupKey, new List<HS_Inbound_Stamp__c>());
      }
      byGroup.get(groupKey).put(row.HubSpot_Id__c, row.Record_Id__c);
      rowsByGroup.get(groupKey).add(row);
    }

    // --- Callouts ---
    Map<String, String> failuresByHsId = new Map<String, String>();
    Set<String> unconfigured = new Set<String>();
    for (String groupKey : byGroup.keySet()) {
      HS_Inbound_Stamp__c sample = rowsByGroup.get(groupKey)[0];
      PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig(
        sample.SObject_Name__c
      );
      if (cfg == null) {
        // Config was removed after the row was queued. Treat every row
        // as failed so an admin can restore the config and let it retry,
        // rather than dropping the write-back silently.
        unconfigured.add(groupKey);
        continue;
      }
      failuresByHsId.putAll(
        HubSpotService.batchStampSfId(
          cfg,
          sample.Portal__c,
          byGroup.get(groupKey)
        )
      );
    }

    // --- DML ---
    List<HS_Inbound_Stamp__c> done = new List<HS_Inbound_Stamp__c>();
    List<HS_Inbound_Stamp__c> retry = new List<HS_Inbound_Stamp__c>();
    // object -> ids to release into the outbox
    Map<String, Set<Id>> releaseByObject = new Map<String, Set<Id>>();

    for (String groupKey : rowsByGroup.keySet()) {
      Boolean groupUnconfigured = unconfigured.contains(groupKey);
      for (HS_Inbound_Stamp__c row : rowsByGroup.get(groupKey)) {
        String detail = groupUnconfigured
          ? 'No Portal_Sync_Object__mdt configuration for ' +
            row.SObject_Name__c
          : failuresByHsId.get(row.HubSpot_Id__c);
        if (detail == null) {
          done.add(row);
          if (!releaseByObject.containsKey(row.SObject_Name__c)) {
            releaseByObject.put(row.SObject_Name__c, new Set<Id>());
          }
          releaseByObject.get(row.SObject_Name__c).add((Id) row.Record_Id__c);
          continue;
        }
        Integer priorRetries = (row.Retry_Count__c == null)
          ? 0
          : row.Retry_Count__c.intValue();
        row.Status__c = PortalSyncConfig.STATUS_FAILED;
        row.Retry_Count__c = priorRetries + 1;
        retry.add(row);
        PortalSyncDeadLetter.log(
          row.SObject_Name__c,
          row.Record_Id__c,
          row.Portal__c,
          'INBOUND_STAMP',
          'HubSpot ' + row.HubSpot_Id__c + ': ' + detail
        );

        if (row.Retry_Count__c >= PortalSyncConfig.MAX_RETRIES) {
          // The row is KEPT, not deleted. Deleting it would permanently
          // reopen the duplicate-creation window: the HubSpot record
          // still has no sf-id, so a later poll would import it again.
          // The Salesforce record also stays in Awaiting_Writeback, so
          // it is never pushed as a duplicate either. Both need manual
          // repair -- hence the loud message.
          PortalSyncDeadLetter.log(
            row.SObject_Name__c,
            row.Record_Id__c,
            row.Portal__c,
            'INBOUND_STAMP',
            'Retries exhausted writing ' +
              row.Record_Id__c +
              ' to HubSpot ' +
              row.HubSpot_Id__c +
              ' in ' +
              row.Portal__c +
              '. The stamp row is retained deliberately; the Salesforce record stays ' +
              'held out of the outbox until this is repaired manually.'
          );
        }
      }
    }

    if (!retry.isEmpty())
      Database.update(retry, false);
    releaseRecords(releaseByObject);
    if (!done.isEmpty())
      Database.delete(done, false);
    PortalSyncDeadLetter.flush();
  }

  public void finish(Database.BatchableContext bc) {
  }

  /**
   * Move each successfully stamped record out of Awaiting_Writeback and into
   * Pending, so the outbox picks it up on its next drain and fans the record
   * out to every portal its Portal__c selects. Until this runs the record is
   * invisible to the outbox by design.
   */
  private static void releaseRecords(Map<String, Set<Id>> releaseByObject) {
    for (String sObjectName : releaseByObject.keySet()) {
      PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig(
        sObjectName
      );
      if (cfg == null)
        continue;
      Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectName);
      if (sot == null)
        continue;
      List<SObject> shells = new List<SObject>();
      for (Id recordId : releaseByObject.get(sObjectName)) {
        SObject shell = sot.newSObject(recordId);
        shell.put(cfg.statusField, PortalSyncConfig.STATUS_PENDING);
        shell.put(cfg.retryCountField, 0);
        shells.add(shell);
      }
      if (!shells.isEmpty()) {
        Database.SaveResult[] results = Database.update(shells, false);
        for (Integer i = 0; i < results.size(); i++) {
          if (results[i].isSuccess())
            continue;
          PortalSyncDeadLetter.log(
            sObjectName,
            String.valueOf(shells[i].Id),
            null,
            'INBOUND_RELEASE',
            'Stamped in HubSpot but could not be released into the outbox: ' +
            results[i].getErrors()[0].getMessage()
          );
        }
      }
    }
  }
}
