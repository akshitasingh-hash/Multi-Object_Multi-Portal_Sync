/**
 * Shared batch-overlap guard for both sync directions.
 *
 * The engine never claims rows: callout-first/DML-last forbids the DML that
 * claiming would need, so overlap is prevented by not LAUNCHING a second job
 * rather than by locking records. Each object therefore has its own concrete
 * batch class name (AsyncApexJob cannot expose constructor arguments), and the
 * guard keys on AsyncApexJob.ApexClass.Name.
 *
 * The guard must be MUTUAL across directions. Without it: the outbox reads a
 * record as Pending and calls out; inbound concurrently applies a HubSpot value
 * and re-stamps Pending; the outbox's DML phase then writes Synced last and the
 * inbound-won value's fan-out is silently lost until the nightly reconciliation.
 * Not corruption, but an invisible lost update -- so both schedulers ask about
 * both class names.
 */
public with sharing class PortalSyncJobs {
  private static final Set<String> LIVE_STATUSES = new Set<String>{
    'Holding',
    'Queued',
    'Preparing',
    'Processing'
  };

  /** True when ANY of these batch classes currently has a live job. Blank and
   *  null names are ignored, so an object with no inbound class configured
   *  simply contributes nothing to the question. */
  public static Boolean isAnyRunning(Set<String> classNames) {
    Set<String> names = new Set<String>();
    if (classNames != null) {
      for (String name : classNames) {
        if (String.isNotBlank(name))
          names.add(name);
      }
    }
    if (names.isEmpty())
      return false;
    List<AsyncApexJob> jobs = [
      SELECT Id
      FROM AsyncApexJob
      WHERE
        JobType = 'BatchApex'
        AND Status IN :LIVE_STATUSES
        AND ApexClass.Name IN :names
      LIMIT 1
    ];
    return !jobs.isEmpty();
  }

  /** Convenience for the single-class case. */
  public static Boolean isRunning(String className) {
    return isAnyRunning(new Set<String>{ className });
  }

  /** Both of an object's batch classes -- what either scheduler must check
   *  before launching either direction. */
  public static Set<String> bothDirections(PortalSyncConfig.ObjectConfig cfg) {
    return new Set<String>{ cfg.outboxBatchClass, cfg.inboundBatchClass };
  }
}
