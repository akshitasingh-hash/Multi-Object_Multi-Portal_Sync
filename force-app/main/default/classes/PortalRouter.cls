/**
 * The routing brain, shared by the outbox batch and the reconciliation batch.
 * Generic over object type: it is handed a PortalSyncConfig.ObjectConfig and
 * routes any SObject, so the same logic drives contacts, companies, etc.
 *
 * syncRecords upserts each record into the portal(s) matching its portal field.
 * It archives from the OTHER portals only when archiveOthers=true -- the outbox
 * passes this per group (the record's portal-changed flag), so routine field
 * edits skip the archive sweep and only real portal moves pay for it. The
 * reconciliation batch passes true to stay fully self-healing.
 *
 * It is BULK: records are grouped by portal and pushed through HubSpot's batch
 * endpoints, so a scope of N records costs O(enabled portals) callouts instead
 * of O(N). This is what lets the outbox handle mass changes.
 *
 * Returns sfId -> TRUE on full success. Failures are BUFFERED in
 * PortalSyncDeadLetter; the caller must PortalSyncDeadLetter.flush() AFTER all
 * callouts (never between them -- DML between callouts throws in Apex).
 */
public with sharing class PortalRouter {

    public static Map<Id, Boolean> syncRecords(PortalSyncConfig.ObjectConfig cfg, List<SObject> records, Boolean archiveOthers) {
        Map<Id, Boolean> result = new Map<Id, Boolean>();
        if (records == null || records.isEmpty()) return result;

        // portal -> (sfId -> mapped props) to upsert
        Map<String, Map<String, Map<String, Object>>> upsertByPortal =
            new Map<String, Map<String, Map<String, Object>>>();
        // portal -> set of sfIds to archive
        Map<String, Set<String>> archiveByPortal = new Map<String, Set<String>>();

        List<String> enabled = PortalSyncConfig.allPortalValues();

        for (SObject record : records) {
            String sfId = record.Id;
            result.put(record.Id, true);

            // The portal field is multiselect -> a record can belong to several portals.
            Set<String> selected = PortalSyncConfig.selectedPortals(record, cfg);

            if (selected.isEmpty()) {
                // Belongs to no enabled portal -> should exist nowhere.
                for (String p : enabled) addTo(archiveByPortal, p, sfId);
                continue;
            }

            // Properties are resolved per portal: each portal receives only the
            // fields whose mapping opts into it (Syncs_To_*).
            for (String p : selected) {
                if (!upsertByPortal.containsKey(p)) {
                    upsertByPortal.put(p, new Map<String, Map<String, Object>>());
                }
                upsertByPortal.get(p).put(sfId, HubSpotService.mapProperties(record, cfg.sObjectName, p));
            }
            if (archiveOthers) {
                for (String p : enabled) {
                    if (!selected.contains(p)) addTo(archiveByPortal, p, sfId);
                }
            }
        }

        // Callouts: all upserts, then all archives. Failures mark the record and
        // buffer a dead-letter row; the caller flushes after every callout.
        for (String p : upsertByPortal.keySet()) {
            Map<String, String> failed = HubSpotService.batchUpsertBySfId(cfg, p, upsertByPortal.get(p));
            for (String sfId : failed.keySet()) {
                PortalSyncDeadLetter.log(cfg.sObjectName, sfId, p, 'UPSERT', failed.get(sfId));
                result.put((Id) sfId, false);
            }
        }
        for (String p : archiveByPortal.keySet()) {
            Map<String, String> failed = HubSpotService.batchArchiveBySfId(cfg, p, archiveByPortal.get(p));
            for (String sfId : failed.keySet()) {
                PortalSyncDeadLetter.log(cfg.sObjectName, sfId, p, 'ARCHIVE', failed.get(sfId));
                result.put((Id) sfId, false);
            }
        }
        return result;
    }

    /**
     * Bulk archive from every enabled portal (for hard-deleted records, whose
     * portal membership is gone). Returns the sfIds that failed to fully archive.
     */
    public static Set<String> archiveEverywhere(PortalSyncConfig.ObjectConfig cfg, List<String> sfIds) {
        Set<String> failed = new Set<String>();
        Set<String> ids = new Set<String>(sfIds);
        if (ids.isEmpty()) return failed;
        for (String p : PortalSyncConfig.allPortalValues()) {
            Map<String, String> f = HubSpotService.batchArchiveBySfId(cfg, p, ids);
            for (String sfId : f.keySet()) {
                PortalSyncDeadLetter.log(cfg.sObjectName, sfId, p, 'ARCHIVE', f.get(sfId));
                failed.add(sfId);
            }
        }
        return failed;
    }

    private static void addTo(Map<String, Set<String>> m, String portal, String sfId) {
        if (!m.containsKey(portal)) m.put(portal, new Set<String>());
        m.get(portal).add(sfId);
    }
}
