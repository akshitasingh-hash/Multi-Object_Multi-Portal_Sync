/**
 * Self-healing backstop for one object. Re-asserts recently modified records with
 * a FULL archive-from-others sweep (archiveOthers = true), so it repairs both
 * missed upserts and any record that somehow lingers in a wrong portal. Schedule
 * nightly per object; it complements the 15-min outbox, it does not replace it.
 *
 * It writes status like the outbox batch, so a repaired record flips to Synced --
 * but ONLY when the status actually changes. Updating every record it touched
 * would keep those records inside its own LastModifiedDate look-back window, so
 * the nightly working set would grow without bound towards the whole table.
 * Residual gap (same as always): a record hard-deleted in Salesforce while the
 * integration was down longer than tombstones survive would need a HubSpot-side
 * orphan listing to catch -- add that separately if it matters.
 */
public with sharing class PortalSyncReconciliationBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Schedulable {
  private final PortalSyncConfig.ObjectConfig cfg;
  private Integer lookbackDays;

  public PortalSyncReconciliationBatch() {
    this('Contact', 2);
  }
  public PortalSyncReconciliationBatch(Integer lookbackDays) {
    this('Contact', lookbackDays);
  }
  public PortalSyncReconciliationBatch(String sObjectName) {
    this(sObjectName, 2);
  }
  public PortalSyncReconciliationBatch(
    String sObjectName,
    Integer lookbackDays
  ) {
    this.cfg = PortalSyncConfig.objectConfig(sObjectName);
    if (this.cfg == null) {
      throw new IllegalArgumentException(
        'No Portal_Sync_Object__mdt configuration for SObject: ' + sObjectName
      );
    }
    this.lookbackDays = lookbackDays;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    Set<String> fields = new Set<String>{
      'Id',
      cfg.portalField,
      cfg.statusField
    };
    fields.addAll(PortalSyncConfig.mappedSfFields(cfg.sObjectName));
    fields.addAll(PortalSyncConfig.associationSourceFields(cfg.sObjectName));
    if (cfg.syncOwner)
      fields.add('Owner.Email');
    // Provenance, for the shared-ownership comparison in PortalRouter.
    if (String.isNotBlank(cfg.contentChangedField)) {
      fields.add(cfg.contentChangedField);
      fields.add('CreatedDate');
    }
    // A record inbound created but has not yet stamped back into HubSpot is
    // excluded here for the same reason the outbox query excludes it:
    // pushing it would upsert by sf-id property, match nothing, and create a
    // SECOND HubSpot record beside the original.
    String awaiting = PortalSyncConfig.STATUS_AWAITING_WRITEBACK;
    return Database.getQueryLocator(
      'SELECT ' +
        String.join(new List<String>(fields), ', ') +
        ' FROM ' +
        cfg.sObjectName +
        ' WHERE LastModifiedDate = LAST_N_DAYS:' +
        this.lookbackDays +
        ' AND ' +
        cfg.statusField +
        ' != :awaiting'
    );
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    Map<Id, Boolean> success = PortalRouter.syncRecords(cfg, scope, true); // full sweep, bulk

    // Reassert associations (full create + archive diff) for records that
    // synced OK -- callout phase, before the DML below.
    List<SObject> synced = new List<SObject>();
    for (SObject record : scope) {
      if (success.get(record.Id) == true)
        synced.add(record);
    }
    PortalAssociationRouter.syncAssociations(cfg, synced);

    // DML ONLY where the status actually changes.
    //
    // This used to update every record in scope, which made the batch
    // self-perpetuating: its own DML bumped LastModifiedDate, which kept the
    // record inside this very query's LAST_N_DAYS window, so the nightly
    // working set only ever grew -- towards the whole table. Re-asserting an
    // unchanged record in HubSpot is free (HubSpot does not bump
    // hs_lastmodifieddate for a write that changes nothing), so skipping the
    // bookkeeping write costs nothing and lets healthy records fall out of
    // the window as intended.
    Schema.SObjectType sot = Schema.getGlobalDescribe().get(cfg.sObjectName);
    List<SObject> updates = new List<SObject>();
    for (SObject record : scope) {
      Boolean ok = success.get(record.Id) == true;
      String desired = ok
        ? PortalSyncConfig.STATUS_SYNCED
        : PortalSyncConfig.STATUS_FAILED;
      String current = (String) record.get(cfg.statusField);
      if (desired.equals(current))
        continue; // nothing to record
      SObject u = sot.newSObject((Id) record.Id);
      u.put(cfg.lastSyncField, System.now());
      u.put(cfg.statusField, desired);
      updates.add(u);
    }
    if (!updates.isEmpty())
      update updates;
    PortalSyncDeadLetter.flush();
  }

  public void finish(Database.BatchableContext bc) {
  }

  public void execute(SchedulableContext sc) {
    Database.executeBatch(
      new PortalSyncReconciliationBatch(
        this.cfg.sObjectName,
        this.lookbackDays
      ),
      PortalSyncConfig.BATCH_SCOPE
    );
  }
}
