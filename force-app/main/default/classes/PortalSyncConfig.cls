/**
 * Environment wiring + outbox constants for the generic portal sync.
 *
 * Two dimensions drive everything:
 *   - PORTALS (shared across objects): a portal is a HubSpot account fronted by a
 *     Named Credential. The same portal hosts contacts, companies, etc., so the
 *     portal maps below stay object-agnostic.
 *   - OBJECTS (Portal_Sync_Object__mdt): one row per synced SObject naming its
 *     HubSpot path, its sf-id property, and the API names of its portal + HS_*
 *     status fields. Admins add an object row (plus its mapping rows) with no
 *     deploy; the only per-object Apex is a thin trigger + one-line batch subclass.
 */
public with sharing class PortalSyncConfig {

    // Portal value -> Named Credential. Only ENABLED portals belong here; a
    // portal removed from this map is fully disabled (no callouts ever reach it,
    // and it is ignored when parsing a record's portal field). Shared by every
    // synced object. Re-enable by uncommenting.
    public static final Map<String, String> PORTAL_TO_NAMED_CREDENTIAL = new Map<String, String>{
        'Carl'  => 'HubSpot_Carl',
        'TriBU' => 'HubSpot_TriBU',
        'Spain' => 'HubSpot_Spain'
    };

    // Portal value -> the HubSpot_Field_Mapping__mdt checkbox that gates whether a
    // field syncs to THAT portal. Every enabled portal in PORTAL_TO_NAMED_CREDENTIAL
    // needs an entry here; a portal missing from this map syncs no fields at all.
    private static final Map<String, String> PORTAL_TO_SYNC_FIELD = new Map<String, String>{
        'Carl'  => 'Syncs_To_CARL__c',
        'TriBU' => 'Syncs_To_TriBU__c',
        'Spain' => 'Syncs_To_Spain__c'
    };

    // Outbox status values (per-object status field and tombstone Status__c).
    public static final String STATUS_PENDING    = 'Pending';
    public static final String STATUS_PROCESSING = 'Processing';
    public static final String STATUS_SYNCED     = 'Synced';
    public static final String STATUS_FAILED     = 'Failed';

    // Batch scope. The router uses HubSpot's batch endpoints, so callouts scale
    // with the number of enabled portals -- NOT with the record count. Scope
    // tracks HubSpot's 100-records-per-batch sweet spot.
    public static final Integer BATCH_SCOPE = 100;

    // A Failed row is retried until it hits this cap, then left for manual review.
    public static final Integer MAX_RETRIES = 5;

    // ---- Per-object configuration (Portal_Sync_Object__mdt) -----------------

    /** Resolved configuration for one synced SObject. All the object-specific
     *  wiring the generic engine needs: HubSpot endpoint, match key, and the API
     *  names of the object's portal + governance fields (configurable per object,
     *  so different objects may use different field names). */
    public class ObjectConfig {
        public String sObjectName;
        public String hubSpotPath;        // /crm/v3/objects/{hubSpotPath}
        public String sfIdProperty;       // HubSpot unique property holding the SF id
        public String portalField;        // multiselect portal field API name
        public String statusField;        // sync status field API name
        public String portalChangedField; // "portal moved" flag field API name
        public String retryCountField;    // retry counter field API name
        public String lastSyncField;      // last-sync datetime field API name
        public String syncMessageField;   // human-readable message field API name
        public String outboxBatchClass;   // Apex class the scheduler launches
        public Boolean active;
    }

    // Loaded lazily and cached for the life of the transaction. getAll() does not
    // consume a SOQL query.
    private static Map<String, ObjectConfig> objectConfigsByName;

    private static Map<String, ObjectConfig> objectConfigs() {
        if (objectConfigsByName == null) {
            objectConfigsByName = new Map<String, ObjectConfig>();
            for (Portal_Sync_Object__mdt o : Portal_Sync_Object__mdt.getAll().values()) {
                if (String.isBlank(o.SObject_API_Name__c)) continue;
                ObjectConfig cfg = new ObjectConfig();
                cfg.sObjectName        = o.SObject_API_Name__c;
                cfg.hubSpotPath        = o.HubSpot_Object_Path__c;
                cfg.sfIdProperty       = o.SF_Id_Property__c;
                cfg.portalField        = o.Portal_Field__c;
                cfg.statusField        = o.Sync_Status_Field__c;
                cfg.portalChangedField = o.Portal_Changed_Field__c;
                cfg.retryCountField    = o.Retry_Count_Field__c;
                cfg.lastSyncField      = o.Last_Sync_Field__c;
                cfg.syncMessageField   = o.Sync_Message_Field__c;
                cfg.outboxBatchClass   = o.Outbox_Batch_Class__c;
                cfg.active             = (o.Active__c == true);
                objectConfigsByName.put(cfg.sObjectName, cfg);
            }
        }
        return objectConfigsByName;
    }

    /** Config for one object (null if the object has no Portal_Sync_Object__mdt row). */
    public static ObjectConfig objectConfig(String sObjectName) {
        return objectConfigs().get(sObjectName);
    }

    /** Every enabled object -- what the scheduler iterates to launch outboxes. */
    public static List<ObjectConfig> activeObjects() {
        List<ObjectConfig> result = new List<ObjectConfig>();
        for (ObjectConfig cfg : objectConfigs().values()) {
            if (cfg.active) result.add(cfg);
        }
        return result;
    }

    // ---- Field mappings (HubSpot_Field_Mapping__mdt), keyed per object -------
    // The SF->HS field contract is PER OBJECT and PER PORTAL: a field belongs to
    // (object, portal) only when its mapping row is Active__c, names that object
    // in SObject__c, AND that portal's Syncs_To_* checkbox is checked. All
    // admin-managed so the contract can change without a deploy.
    // object -> portal -> (SF field API name -> HubSpot property)
    private static Map<String, Map<String, Map<String, String>>> fieldMapByObjectPortal;

    private static Map<String, Map<String, Map<String, String>>> fieldMaps() {
        if (fieldMapByObjectPortal == null) {
            fieldMapByObjectPortal = new Map<String, Map<String, Map<String, String>>>();
            for (HubSpot_Field_Mapping__mdt m : [SELECT Id, Portal_Sync_Object__r.SObject_API_Name__c, Active__c, 
                                                 HubSpot_Property__c, SF_Field__c, Syncs_To_TriBU__c, Syncs_To_CARL__c,
                                                 Syncs_To_Spain__c, Portal_Sync_Object__r.HubSpot_Object_Path__c
                                                 FROM HubSpot_Field_Mapping__mdt
                                                 WHERE Portal_Sync_Object__r.Active__c = true
                                                 AND Active__c = true]) {
                if (!m.Active__c
                        || String.isBlank(m.Portal_Sync_Object__r.SObject_API_Name__c)
                        || String.isBlank(m.SF_Field__c)
                        || String.isBlank(m.HubSpot_Property__c)) {
                    continue;
                }
                String obj = m.Portal_Sync_Object__r.SObject_API_Name__c;
                if (!fieldMapByObjectPortal.containsKey(obj)) {
                    Map<String, Map<String, String>> byPortal = new Map<String, Map<String, String>>();
                    for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
                        byPortal.put(portal, new Map<String, String>());
                    }
                    fieldMapByObjectPortal.put(obj, byPortal);
                }
                for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
                    Object syncsToPortal = m.get(PORTAL_TO_SYNC_FIELD.get(portal));
                    if (syncsToPortal != null && (Boolean) syncsToPortal) {
                        fieldMapByObjectPortal.get(obj).get(portal).put(m.SF_Field__c, m.HubSpot_Property__c);
                    }
                }
            }
        }
        return fieldMapByObjectPortal;
    }

    // SF field -> HubSpot property for a single (object, portal). Empty for an
    // unknown/opted-out combination. This is what a callout to `portal` sends.
    public static Map<String, String> fieldMapFor(String sObjectName, String portal) {
        Map<String, Map<String, String>> byPortal = fieldMaps().get(sObjectName);
        if (byPortal == null) return new Map<String, String>();
        Map<String, String> m = byPortal.get(portal);
        return (m != null) ? m : new Map<String, String>();
    }

    // The UNION of every portal's fields for one object -- every SF field that
    // syncs to at least one portal. Used to build outbox/reconciliation SOQL and
    // to decide when an edit is sync-relevant, both of which must cover all portals.
    public static Set<String> mappedSfFields(String sObjectName) {
        Set<String> fields = new Set<String>();
        Map<String, Map<String, String>> byPortal = fieldMaps().get(sObjectName);
        if (byPortal != null) {
            for (Map<String, String> m : byPortal.values()) {
                fields.addAll(m.keySet());
            }
        }
        return fields;
    }

    public static List<String> allPortalValues() {
        return new List<String>(PORTAL_TO_NAMED_CREDENTIAL.keySet());
    }

    /**
     * The portal field is a MULTISELECT picklist, so its value arrives as a
     * semicolon-delimited string (e.g. "TriBU;CARL"). Split it and keep only the
     * portals that are currently enabled (present in PORTAL_TO_NAMED_CREDENTIAL);
     * unknown or disabled selections are dropped. Returns an empty set when the
     * record belongs to no enabled portal.
     */
    public static Set<String> selectedPortals(SObject record, ObjectConfig cfg) {
        Set<String> result = new Set<String>();
        String raw = (String) record.get(cfg.portalField);
        if (String.isBlank(raw)) return result;
        for (String value : raw.split(';')) {
            String portal = value.trim();
            if (PORTAL_TO_NAMED_CREDENTIAL.containsKey(portal)) {
                result.add(portal);
            }
        }
        return result;
    }
}
