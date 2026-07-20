/**
 * Asserts HubSpot associations for a set of FROM-object records, shared by the
 * outbox batch (15-min pass) and the reconciliation batch (nightly). Generic:
 * handed the From object's PortalSyncConfig.ObjectConfig, it reads every active
 * Portal_Sync_Association__mdt row owned by that object and reconciles each.
 *
 * An association LINKS two already-synced records by their HubSpot ids, so this
 * runs AFTER the record upserts (its callouts join the batch's callout phase,
 * before any DML). It is an idempotent DIFF per (association, portal, from-record):
 *   1. resolve the from-record and its related to-records to HubSpot ids
 *      (per portal, via the object's sf-id property) -- a side not yet synced to
 *      the portal is simply skipped this cycle and picked up on the next pass;
 *   2. read the from-record's existing associations of this type;
 *   3. CREATE the desired links that are missing, ARCHIVE the ones Salesforce no
 *      longer relates.
 * Because the diff is computed per from-record from its full desired set, it is
 * safe on any scope and needs no ordering guarantee between object outboxes.
 *
 * Portal isolation is automatic: ids are resolved within a single portal's Named
 * Credential, so a portal only ever links its own records.
 *
 * Failures are BUFFERED in PortalSyncDeadLetter (Operation ASSOCIATE / DISASSOCIATE)
 * and never flip the from-record's sync status -- the field sync already
 * succeeded and a failed link self-heals on the next pass. The caller flushes
 * the dead letter after all callouts (never between them).
 */
public with sharing class PortalAssociationRouter {

    public static void syncAssociations(PortalSyncConfig.ObjectConfig fromCfg, List<SObject> records) {
        if (records == null || records.isEmpty()) return;
        List<PortalSyncConfig.AssociationConfig> assocs =
            PortalSyncConfig.associationsFrom(fromCfg.sObjectName);
        if (assocs.isEmpty()) return;

        for (PortalSyncConfig.AssociationConfig a : assocs) {
            // fromSfId -> set of related toSfId (SF-id space), for the whole scope.
            Map<Id, Set<String>> desiredBySf = desiredPairs(a, records);
            for (String portal : PortalSyncConfig.allPortalValues()) {
                if (!a.syncsTo(portal)) continue;
                reconcilePortal(a, portal, records, desiredBySf);
            }
        }
    }

    /** Resolve each from-record's related to-record SF ids, per source type. */
    private static Map<Id, Set<String>> desiredPairs(
            PortalSyncConfig.AssociationConfig a, List<SObject> records) {
        Map<Id, Set<String>> desired = new Map<Id, Set<String>>();
        for (SObject record : records) desired.put(record.Id, new Set<String>());

        if (a.isJunction()) {
            if (String.isBlank(a.junctionObject) || String.isBlank(a.junctionFromField)
                    || String.isBlank(a.junctionToField)) {
                return desired;
            }
            String soql =
                'SELECT ' + a.junctionFromField + ', ' + a.junctionToField +
                ' FROM ' + a.junctionObject +
                ' WHERE ' + a.junctionFromField + ' IN :fromIds';
            Set<Id> fromIds = desired.keySet();
            for (SObject link : Database.query(soql)) {
                Id fromId = (Id) link.get(a.junctionFromField);
                Object toId = link.get(a.junctionToField);
                if (fromId != null && toId != null && desired.containsKey(fromId)) {
                    desired.get(fromId).add(String.valueOf(toId));
                }
            }
        } else {
            if (String.isBlank(a.relationshipField)) return desired;
            for (SObject record : records) {
                Object toId = record.get(a.relationshipField);
                if (toId != null) desired.get(record.Id).add(String.valueOf(toId));
            }
        }
        return desired;
    }

    private static void reconcilePortal(
            PortalSyncConfig.AssociationConfig a, String portal,
            List<SObject> records, Map<Id, Set<String>> desiredBySf) {

        PortalSyncConfig.ObjectConfig fromCfg = PortalSyncConfig.objectConfig(a.fromObject);
        PortalSyncConfig.ObjectConfig toCfg   = PortalSyncConfig.objectConfig(a.toObject);
        if (fromCfg == null || toCfg == null) return;

        // Only from-records that belong to this portal can be linked here.
        List<String> fromSfIds = new List<String>();
        Set<String> toSfIds = new Set<String>();
        for (SObject record : records) {
            if (!PortalSyncConfig.selectedPortals(record, fromCfg).contains(portal)) continue;
            fromSfIds.add(record.Id);
            toSfIds.addAll(desiredBySf.get(record.Id));
        }
        if (fromSfIds.isEmpty()) return;

        // Resolve both ends to HubSpot ids in this portal.
        Map<String, String> fromResolveFailed = new Map<String, String>();
        Map<String, String> fromHsBySf = resolveAll(fromCfg, portal, fromSfIds, fromResolveFailed);

        Map<String, String> toResolveFailed = new Map<String, String>();
        Map<String, String> toHsBySf = new Map<String, String>();
        if (!toSfIds.isEmpty()) {
            toHsBySf = resolveAll(toCfg, portal, new List<String>(toSfIds), toResolveFailed);
        }
        Boolean toReadUnreliable = !toResolveFailed.isEmpty();

        // fromHsId -> its fromSfId, for dead-letter tagging.
        Map<String, Id> fromSfByHs = new Map<String, Id>();
        List<String> fromHsIds = new List<String>();
        for (SObject record : records) {
            String hs = fromHsBySf.get(record.Id);
            if (hs != null) { fromHsIds.add(hs); fromSfByHs.put(hs, record.Id); }
        }
        if (fromHsIds.isEmpty()) return;

        // Existing associations of this type, per from-record.
        Map<String, String> readFailed = new Map<String, String>();
        Map<String, Set<String>> existingByFromHs = HubSpotService.batchReadAssociations(
            a.fromHubSpotPath, a.toHubSpotPath, portal, fromHsIds,
            a.associationCategory, a.associationTypeId, readFailed);

        List<HubSpotService.AssocInput> toCreate = new List<HubSpotService.AssocInput>();
        List<HubSpotService.AssocInput> toArchive = new List<HubSpotService.AssocInput>();

        for (SObject record : records) {
            String fromHs = fromHsBySf.get(record.Id);
            if (fromHs == null) continue;

            // Desired to-ids in HubSpot-id space; note any that did not resolve.
            Set<String> desiredHs = new Set<String>();
            Boolean anyDesiredUnresolved = false;
            for (String toSf : desiredBySf.get(record.Id)) {
                String toHs = toHsBySf.get(toSf);
                if (toHs != null) desiredHs.add(toHs); else anyDesiredUnresolved = true;
            }

            Set<String> existing = existingByFromHs.containsKey(fromHs)
                ? existingByFromHs.get(fromHs) : new Set<String>();

            for (String toHs : desiredHs) {
                if (!existing.contains(toHs)) toCreate.add(new HubSpotService.AssocInput(fromHs, toHs));
            }

            // Only remove when we can trust the desired set: the from-record's
            // associations were read OK, every to-id resolved, and no to-resolve
            // callout failed (an unresolved id must not be mistaken for "removed").
            Boolean removalsSafe = !readFailed.containsKey(fromHs)
                && !anyDesiredUnresolved && !toReadUnreliable;
            if (removalsSafe) {
                for (String toHs : existing) {
                    if (!desiredHs.contains(toHs)) toArchive.add(new HubSpotService.AssocInput(fromHs, toHs));
                }
            }
        }

        // Callouts: creates then archives. Buffer failures for the caller to flush.
        if (!toCreate.isEmpty()) {
            Map<String, String> failed = HubSpotService.batchCreateAssociations(
                a.fromHubSpotPath, a.toHubSpotPath, portal,
                a.associationCategory, a.associationTypeId, toCreate);
            logFailures(a, portal, 'ASSOCIATE', failed, fromSfByHs);
        }
        if (!toArchive.isEmpty()) {
            Map<String, String> failed = HubSpotService.batchArchiveAssociations(
                a.fromHubSpotPath, a.toHubSpotPath, portal, toArchive);
            logFailures(a, portal, 'DISASSOCIATE', failed, fromSfByHs);
        }
    }

    /** resolveHubSpotIds handles one <=100 chunk; loop it over the full list. */
    private static Map<String, String> resolveAll(
            PortalSyncConfig.ObjectConfig cfg, String portal, List<String> sfIds, Map<String, String> failed) {
        Map<String, String> hsBySf = new Map<String, String>();
        Integer limitSize = PortalSyncConfig.BATCH_SCOPE;
        for (Integer i = 0; i < sfIds.size(); i += limitSize) {
            Integer stop = Math.min(i + limitSize, sfIds.size());
            List<String> chunk = new List<String>();
            for (Integer j = i; j < stop; j++) chunk.add(sfIds[j]);
            hsBySf.putAll(HubSpotService.resolveHubSpotIds(cfg, portal, chunk, failed));
        }
        return hsBySf;
    }

    private static void logFailures(
            PortalSyncConfig.AssociationConfig a, String portal, String operation,
            Map<String, String> failed, Map<String, Id> fromSfByHs) {
        for (String key : failed.keySet()) {
            String fromHs = key.substringBefore('>');
            Id fromSf = fromSfByHs.get(fromHs);
            String detail = a.fromObject + '->' + a.toObject + ' [' + key + '] ' + failed.get(key);
            PortalSyncDeadLetter.log(
                a.fromObject, (fromSf != null ? String.valueOf(fromSf) : fromHs),
                portal, operation, detail);
        }
    }
}
