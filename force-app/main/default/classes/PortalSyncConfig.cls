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
        'Carl Software'  => 'HubSpot_Carl',
        'TriBU' => 'HubSpot_TriBU',
        'Berger-Levrault Spain' => 'HubSpot_Spain'
    };

    // Portal value -> the HubSpot_Field_Mapping__mdt checkbox that gates whether a
    // field syncs to THAT portal. Every enabled portal in PORTAL_TO_NAMED_CREDENTIAL
    // needs an entry here; a portal missing from this map syncs no fields at all.
    private static final Map<String, String> PORTAL_TO_SYNC_FIELD = new Map<String, String>{
        'Carl Software'  => 'Syncs_To_CARL__c',
        'TriBU' => 'Syncs_To_TriBU__c',
        'Berger-Levrault Spain' => 'Syncs_To_Spain__c'
    };

    // Portal value -> the Portal_Sync_Association__mdt Number field holding THAT
    // portal's HubSpot association type id. Ids for custom objects and for
    // USER_DEFINED labels are generated inside each portal, so the same logical
    // link (e.g. Asset -> Account) carries a different type id in TriBU, CARL and
    // Spain. A portal whose override is blank falls back to the shared
    // Association_Type_Id__c -- correct for HUBSPOT_DEFINED ids, which are stable
    // across portals. A portal missing from this map can only use the fallback.
    private static final Map<String, String> PORTAL_TO_ASSOC_TYPE_FIELD = new Map<String, String>{
        'Carl Software'  => 'Association_Type_Id_CARL__c',
        'TriBU' => 'Association_Type_Id_TriBU__c',
        'Berger-Levrault Spain' => 'Association_Type_Id_Spain__c'
    };

    // Portal value -> the Portal_Sync_Value_Map__mdt Text field holding THAT
    // portal's translated value. Same shape as the association-type map above and
    // for the same reason: a HubSpot picklist option's INTERNAL VALUE is defined
    // per portal, so "Renewal Business" may be renewal_business in TriBU and
    // renewal in CARL. A portal whose override is blank falls back to the shared
    // HubSpot_Value__c -- correct whenever the portals agree, which is the norm.
    private static final Map<String, String> PORTAL_TO_VALUE_FIELD = new Map<String, String>{
        'Carl Software'  => 'HubSpot_Value_CARL__c',
        'TriBU' => 'HubSpot_Value_TriBU__c',
        'Berger-Levrault Spain' => 'HubSpot_Value_Spain__c'
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
        public Boolean syncOwner;         // resolve Owner by email -> hubspot_owner_id on every portal
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
                cfg.syncOwner          = (o.Sync_Owner__c == true);
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

    // ---- Value maps (Portal_Sync_Value_Map__mdt) -----------------------------
    // Field mappings decide WHICH value moves; value maps decide WHAT it looks
    // like on arrival. Needed wherever the two systems disagree on representation
    // -- above all a Salesforce id or picklist landing in a HubSpot picklist,
    // which rejects any value that is not a defined option.
    //
    // Loaded from its OWN lazy cache, deliberately separate from fieldMaps():
    // triggers call mappedSfFields() on every save and must not pay for a query
    // only the callout path needs.
    //
    // Key is object + SF field (both lowercased) -> portal -> (SF value lowercased
    // -> HubSpot value). Lowercasing both sides of the lookup makes the match
    // case-insensitive, so a value map keeps working if a picklist API value is
    // recased in Salesforce.
    private static Map<String, Map<String, Map<String, String>>> valueMapsByField;

    @TestVisible
    private static String valueMapKey(String sObjectName, String sfField) {
        return (sObjectName + '.' + sfField).toLowerCase();
    }

    private static Map<String, Map<String, Map<String, String>>> valueMaps() {
        if (valueMapsByField == null) {
            valueMapsByField = new Map<String, Map<String, Map<String, String>>>();
            // The owning object is reached through the mapping row, but resolved
            // from getAll() rather than a second relationship hop in the query --
            // one level of traversal is all this needs, and getAll() costs no SOQL.
            Map<String, ObjectConfig> configById = new Map<String, ObjectConfig>();
            for (Portal_Sync_Object__mdt o : Portal_Sync_Object__mdt.getAll().values()) {
                ObjectConfig cfg = objectConfig(o.SObject_API_Name__c);
                if (cfg != null) configById.put(String.valueOf(o.Id), cfg);
            }
            for (Portal_Sync_Value_Map__mdt v : [
                    SELECT Salesforce_Value__c, HubSpot_Value__c, Active__c,
                           HubSpot_Value_TriBU__c, HubSpot_Value_CARL__c, HubSpot_Value_Spain__c,
                           Field_Mapping__r.SF_Field__c, Field_Mapping__r.Active__c,
                           Field_Mapping__r.Portal_Sync_Object__c
                    FROM Portal_Sync_Value_Map__mdt
                    WHERE Active__c = true
                      AND Field_Mapping__r.Active__c = true]) {
                ObjectConfig owner = configById.get(String.valueOf(v.Field_Mapping__r.Portal_Sync_Object__c));
                if (owner == null || !owner.active
                        || String.isBlank(v.Field_Mapping__r.SF_Field__c)
                        || String.isBlank(v.Salesforce_Value__c)) {
                    continue;
                }
                String obj = owner.sObjectName;
                String key = valueMapKey(obj, v.Field_Mapping__r.SF_Field__c);
                if (!valueMapsByField.containsKey(key)) {
                    Map<String, Map<String, String>> byPortal = new Map<String, Map<String, String>>();
                    for (String portal : PORTAL_TO_VALUE_FIELD.keySet()) {
                        byPortal.put(portal, new Map<String, String>());
                    }
                    valueMapsByField.put(key, byPortal);
                }
                String sfValue = v.Salesforce_Value__c.trim().toLowerCase();
                for (String portal : PORTAL_TO_VALUE_FIELD.keySet()) {
                    String hsValue = portalValueOf(v, portal);
                    if (String.isNotBlank(hsValue)) {
                        valueMapsByField.get(key).get(portal).put(sfValue, hsValue);
                    }
                }
            }
        }
        return valueMapsByField;
    }

    /**
     * One row's value for ONE portal: that portal's override if it carries one,
     * else the shared HubSpot_Value__c. Only a NON-BLANK override wins -- a blank
     * one has to fall through to the shared value rather than shadow it, the same
     * rule the association type ids follow.
     */
    @TestVisible
    private static String portalValueOf(Portal_Sync_Value_Map__mdt row, String portal) {
        String overrideField = PORTAL_TO_VALUE_FIELD.get(portal);
        if (overrideField != null) {
            Object own = row.get(overrideField);
            if (own != null && String.isNotBlank((String) own)) return (String) own;
        }
        return row.HubSpot_Value__c;
    }

    /** True when ANY translation is configured for this (object, field) -- i.e.
     *  the field's raw Salesforce value must never be sent as-is. Checked before
     *  translateValue so an untranslated value can be reported rather than
     *  silently shipped to a HubSpot picklist that would reject it. */
    public static Boolean hasValueMap(String sObjectName, String sfField) {
        return valueMaps().containsKey(valueMapKey(sObjectName, sfField));
    }

    /**
     * The HubSpot value to send for one Salesforce value in ONE portal, or null
     * when this (object, field, portal) has no row for it. Null is meaningful:
     * the caller must omit the property rather than guess, because an undefined
     * picklist option fails the record in HubSpot.
     */
    public static String translateValue(String sObjectName, String sfField, String portal, String rawValue) {
        if (rawValue == null) return null;
        Map<String, Map<String, String>> byPortal = valueMaps().get(valueMapKey(sObjectName, sfField));
        if (byPortal == null) return null;
        Map<String, String> values = byPortal.get(portal);
        return (values != null) ? values.get(rawValue.trim().toLowerCase()) : null;
    }

    /** Custom Metadata cannot be inserted in a test, so tests seed the cache
     *  directly: key -> portal -> (SF value lowercased -> HubSpot value). */
    @TestVisible
    private static void setValueMapsForTest(Map<String, Map<String, Map<String, String>>> maps) {
        valueMapsByField = maps;
    }

    // ---- Associations (Portal_Sync_Association__mdt) -------------------------
    // HubSpot associations LINK two already-synced records (by their HubSpot ids),
    // rather than sync field values. Each row names a From object, a To object,
    // how the related record's SF id is found (a Lookup field or a Junction
    // object), the HubSpot association type to assert, and the portals it applies
    // to. Driven by the From object's outbox + reconciliation passes.

    /** Resolved configuration for one association type. Carries both objects'
     *  HubSpot path + sf-id property so the router can resolve either side. */
    public class AssociationConfig {
        public String fromObject;
        public String toObject;
        public String fromHubSpotPath;
        public String toHubSpotPath;
        public String fromSfIdProperty;
        public String toSfIdProperty;
        public String sourceType;          // 'Lookup' | 'Junction'
        public String relationshipField;   // Lookup: FK field on the From record
        public String junctionObject;      // Junction: linking SObject API name
        public String junctionFromField;   // Junction: FK -> From record id
        public String junctionToField;     // Junction: FK -> To record id
        public String associationCategory; // HUBSPOT_DEFINED | USER_DEFINED
        public Integer defaultTypeId;      // Association_Type_Id__c -- fallback for every portal
        public Map<String, Integer> typeIdByPortal = new Map<String, Integer>(); // per-portal overrides
        public Map<String, Boolean> portalOptIn = new Map<String, Boolean>();
        public Boolean active;

        public Boolean isJunction() { return 'Junction'.equalsIgnoreCase(sourceType); }
        public Boolean syncsTo(String portal) { return portalOptIn.get(portal) == true; }

        /**
         * The association type id to assert in ONE portal: that portal's override
         * if set, else the shared default. Always ask per portal -- never read
         * defaultTypeId directly -- because custom-object ids differ per portal.
         *
         * Null when neither is configured. The router must then skip the portal
         * rather than guess: a null type id matches EVERY existing association
         * type on read, which would let the diff archive links this row does not
         * own (and HubSpot rejects a create with no type id anyway).
         */
        public Integer typeIdFor(String portal) {
            Integer own = typeIdByPortal.get(portal);
            return (own != null) ? own : defaultTypeId;
        }
    }

    /** A HubSpot association type id is a positive integer, so 0 -- the "not
     *  looked up yet" placeholder in seeded rows -- reads the same as blank. */
    private static Integer assocTypeId(Object raw) {
        if (raw == null) return null;
        Decimal value = (Decimal) raw;
        return (value <= 0) ? null : value.intValue();
    }

    // Loaded lazily and cached for the transaction. from-object name -> its rows.
    private static Map<String, List<AssociationConfig>> associationsByFrom;

    private static Map<String, List<AssociationConfig>> associationConfigs() {
        if (associationsByFrom == null) {
            associationsByFrom = new Map<String, List<AssociationConfig>>();
            for (Portal_Sync_Association__mdt a : [
                    SELECT Source_Type__c, Relationship_Field__c, Junction_Object__c,
                           Junction_From_Field__c, Junction_To_Field__c,
                           Association_Category__c, Association_Type_Id__c, Active__c,
                           Association_Type_Id_TriBU__c, Association_Type_Id_CARL__c,
                           Association_Type_Id_Spain__c,
                           Syncs_To_TriBU__c, Syncs_To_CARL__c, Syncs_To_Spain__c,
                           From_Object__r.SObject_API_Name__c, From_Object__r.HubSpot_Object_Path__c,
                           From_Object__r.SF_Id_Property__c, From_Object__r.Active__c,
                           To_Object__r.SObject_API_Name__c, To_Object__r.HubSpot_Object_Path__c,
                           To_Object__r.SF_Id_Property__c, To_Object__r.Active__c
                    FROM Portal_Sync_Association__mdt
                    WHERE Active__c = true
                      AND From_Object__r.Active__c = true
                      AND To_Object__r.Active__c = true]) {
                if (String.isBlank(a.From_Object__r.SObject_API_Name__c)
                        || String.isBlank(a.To_Object__r.SObject_API_Name__c)) {
                    continue;
                }
                AssociationConfig cfg = new AssociationConfig();
                cfg.fromObject         = a.From_Object__r.SObject_API_Name__c;
                cfg.toObject           = a.To_Object__r.SObject_API_Name__c;
                cfg.fromHubSpotPath    = a.From_Object__r.HubSpot_Object_Path__c;
                cfg.toHubSpotPath      = a.To_Object__r.HubSpot_Object_Path__c;
                cfg.fromSfIdProperty   = a.From_Object__r.SF_Id_Property__c;
                cfg.toSfIdProperty     = a.To_Object__r.SF_Id_Property__c;
                cfg.sourceType         = a.Source_Type__c;
                cfg.relationshipField  = a.Relationship_Field__c;
                cfg.junctionObject     = a.Junction_Object__c;
                cfg.junctionFromField  = a.Junction_From_Field__c;
                cfg.junctionToField    = a.Junction_To_Field__c;
                cfg.associationCategory = String.isBlank(a.Association_Category__c)
                    ? 'HUBSPOT_DEFINED' : a.Association_Category__c;
                cfg.defaultTypeId      = assocTypeId(a.Association_Type_Id__c);
                cfg.active             = (a.Active__c == true);
                for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
                    Object opt = a.get(PORTAL_TO_SYNC_FIELD.get(portal));
                    cfg.portalOptIn.put(portal, opt != null && (Boolean) opt);
                    // Only record a real override; a blank one must fall through
                    // to defaultTypeId, not shadow it with null.
                    String typeIdField = PORTAL_TO_ASSOC_TYPE_FIELD.get(portal);
                    if (typeIdField != null) {
                        Integer own = assocTypeId(a.get(typeIdField));
                        if (own != null) cfg.typeIdByPortal.put(portal, own);
                    }
                }
                if (!associationsByFrom.containsKey(cfg.fromObject)) {
                    associationsByFrom.put(cfg.fromObject, new List<AssociationConfig>());
                }
                associationsByFrom.get(cfg.fromObject).add(cfg);
            }
        }
        return associationsByFrom;
    }

    /** Active associations owned by (driven from) one object. Empty when none. */
    public static List<AssociationConfig> associationsFrom(String sObjectName) {
        List<AssociationConfig> rows = associationConfigs().get(sObjectName);
        return (rows != null) ? rows : new List<AssociationConfig>();
    }

    /** Lookup-source FK fields the From object's outbox/reconciliation SOQL must
     *  select so the router can read the related record id (Junction sources need
     *  no extra field -- they are resolved by a separate query). */
    public static Set<String> associationSourceFields(String sObjectName) {
        Set<String> fields = new Set<String>();
        for (AssociationConfig a : associationsFrom(sObjectName)) {
            if (!a.isJunction() && String.isNotBlank(a.relationshipField)) {
                fields.add(a.relationshipField);
            }
        }
        return fields;
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
