@isTest
public class HubSpotCalloutMock implements HttpCalloutMock {
  // Flip to simulate contacts already existing in a portal (so batch/read and
  // /search resolve them; batch/upsert always echoes its inputs as succeeded).
  public Boolean returnExisting = false;

  // Flip to make every batch endpoint return 500, exercising the failure paths
  // (dead-letter buffering, Failed status, retry increment).
  public Boolean failBatch = false;

  // Flip to make batch/upsert return 207 with the FIRST input missing from
  // results -> that record is treated as failed, the rest succeed.
  public Boolean partialUpsert = false;

  // Flip to throw a CalloutException at the callout layer (timeout/connection),
  // exercising the "don't abort the batch on a callout error" path.
  public Boolean throwCallout = false;

  // Flip to fail ONLY the v4 association endpoints (500) while object upserts
  // still succeed -- exercises association dead-lettering without failing the
  // record's field sync.
  public Boolean failAssociations = false;

  // Flip to make an association batch/read report each from-record as already
  // linked to a stale to-record (id 777001) of the requested type, so the diff
  // produces an archive.
  public Boolean returnExistingAssociations = false;

  // Owner resolution (/crm/v3/owners): when set, the owners list returns one
  // owner with this email/id; leave null to simulate no matching owner.
  public String ownerEmailToMatch = null;
  public String ownerHsId = '555001';

  // Flip to make the owners list endpoint return 500, exercising the
  // "don't fail the record over an unresolved owner" path.
  public Boolean failOwners = false;

  // sfId -> the properties map actually sent on the last /batch/upsert call,
  // so tests can assert on the parsed payload (e.g. hubspot_owner_id) rather
  // than raw JSON.
  public Map<String, Map<String, Object>> capturedUpsertProps = new Map<String, Map<String, Object>>();

  // ---- Inbound: /search --------------------------------------------------

  // Rows the search endpoint returns, oldest first (the engine always sorts
  // ASCENDING). Build them with addSearchResult so a property can be OMITTED
  // rather than set empty -- that distinction is the whole point of the
  // absent-vs-empty rule, and a test cannot exercise it any other way.
  public List<Map<String, Object>> searchRows = new List<Map<String, Object>>();

  // Paged out of searchRows honouring the request's own limit, so the paging
  // loop, the page cap and the watermark advance are all exercised for real.
  private Integer searchOffset = 0;

  public Boolean failSearch = false;
  public Integer searchCallCount = 0;

  // Every search request body, parsed. Tests assert on the FILTER VALUE (the
  // watermark), the requested property list (which proves per-portal direction
  // filtering), the sort direction and the limit.
  public List<Map<String, Object>> capturedSearchBodies = new List<Map<String, Object>>();

  /** Add one search result. Only the properties passed are present in the
   *  response -- anything omitted is genuinely absent, exactly as HubSpot
   *  behaves for a property that has never had a value. */
  public void addSearchResult(String hsId, Map<String, Object> properties) {
    searchRows.add(
      new Map<String, Object>{
        'id' => hsId,
        'properties' => (properties == null)
          ? new Map<String, Object>()
          : properties
      }
    );
  }

  // ---- Inbound: batch/read by HubSpot id (the blank-confirmation pass) ----

  // hsId -> properties the authoritative read returns. Use an explicit null
  // value to model "this property really is empty", which is what batch/read
  // reports and search may not.
  public Map<String, Map<String, Object>> confirmReadProps = new Map<String, Map<String, Object>>();
  public Boolean failConfirmRead = false;
  public Integer confirmReadCallCount = 0;

  // ---- Outbound: batch/read by sf-id (the shared-ownership comparison) ----

  // sfId -> properties (typically hs_lastmodifieddate plus the Bidirectional
  // properties) that the comparison read returns.
  public Map<String, Map<String, Object>> compareProps = new Map<String, Map<String, Object>>();

  // Fail ONLY the comparison read, leaving the upsert working -- so a test can
  // prove the record is failed and retried rather than pushed over a value the
  // engine could not verify.
  public Boolean failCompareRead = false;

  // ---- Inbound: batch/update (the sf-id write-back) ----------------------

  public Boolean failStampBack = false;
  // hsId -> properties sent on /batch/update, so a test can prove the id was
  // written by HubSpot object id and NOT via batch/upsert on the sf-id
  // property (which would create a duplicate HubSpot record).
  public Map<String, Map<String, Object>> capturedUpdateProps = new Map<String, Map<String, Object>>();

  public HttpResponse respond(HttpRequest req) {
    HttpResponse res = new HttpResponse();
    res.setHeader('Content-Type', 'application/json');

    String endpoint = req.getEndpoint();
    Boolean isAssoc = endpoint.contains('/crm/v4/associations/');
    Boolean isOwners = endpoint.contains('/crm/v3/owners');
    if (isOwners) {
      if (failOwners) {
        res.setStatusCode(500);
        res.setBody('{"status":"error","message":"simulated owners failure"}');
        return res;
      }
      List<Object> results = new List<Object>();
      if (ownerEmailToMatch != null) {
        results.add(
          new Map<String, Object>{
            'id' => ownerHsId,
            'email' => ownerEmailToMatch,
            'archived' => false
          }
        );
      }
      res.setStatusCode(200);
      res.setBody(
        JSON.serialize(new Map<String, Object>{ 'results' => results })
      );
      return res;
    }
    if (throwCallout && endpoint.contains('/batch/')) {
      // Simulate a timeout / connection / auth error at the callout layer.
      throw new CalloutException('simulated callout failure');
    }
    if (
      (failBatch || (failAssociations && isAssoc)) &&
      endpoint.contains('/batch/')
    ) {
      res.setStatusCode(500);
      res.setBody('{"status":"error","message":"simulated failure"}');
      return res;
    }
    if (isAssoc) {
      if (endpoint.endsWith('/batch/read')) {
        res.setStatusCode(200);
        res.setBody(echoAssociationRead(req.getBody()));
      } else if (endpoint.endsWith('/batch/create')) {
        res.setStatusCode(201);
        res.setBody('{"status":"COMPLETE","results":[]}');
      } else if (endpoint.endsWith('/batch/archive')) {
        res.setStatusCode(204);
      } else {
        res.setStatusCode(200);
        res.setBody('{"results":[]}');
      }
      return res;
    }
    if (endpoint.endsWith('/search')) {
      return searchResponse(req.getBody(), res);
    }
    if (endpoint.endsWith('/batch/upsert')) {
      captureUpsertProps(req.getBody());
      if (partialUpsert) {
        // 207 multi-status: echo all inputs except the first (which failed).
        res.setStatusCode(207);
        res.setBody(echoResults(req.getBody(), 1));
      } else {
        // Every input succeeds.
        res.setStatusCode(200);
        res.setBody(echoResults(req.getBody(), 0));
      }
    } else if (endpoint.endsWith('/batch/update')) {
      captureUpdateProps(req.getBody());
      if (failStampBack) {
        res.setStatusCode(500);
        res.setBody(
          '{"status":"error","message":"simulated stamp-back failure"}'
        );
      } else {
        res.setStatusCode(200);
        res.setBody('{"status":"COMPLETE","results":[]}');
      }
    } else if (endpoint.endsWith('/batch/read')) {
      return batchReadResponse(req.getBody(), res);
    } else if (endpoint.endsWith('/batch/archive')) {
      res.setStatusCode(204);
    } else if (req.getMethod() == 'DELETE') {
      res.setStatusCode(204);
    } else {
      // POST create or PATCH update
      res.setStatusCode(200);
      res.setBody('{"id":"12345"}');
    }
    return res;
  }

  /**
   * A page of search results out of searchRows, honouring the request's limit
   * and emitting paging.next.after while rows remain -- so the engine's paging
   * loop, page cap and watermark advance are all driven by real pagination
   * rather than a single canned page.
   */
  private HttpResponse searchResponse(String requestBody, HttpResponse res) {
    searchCallCount++;
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    capturedSearchBodies.add(parsed);

    if (failSearch) {
      res.setStatusCode(500);
      res.setBody('{"status":"error","message":"simulated search failure"}');
      return res;
    }

    Integer pageSize = (parsed.get('limit') != null)
      ? Integer.valueOf(String.valueOf(parsed.get('limit')))
      : 100;
    // A request carrying no cursor is a fresh listing, so restart. This is
    // what lets one mock instance serve several portals in one test.
    if (parsed.get('after') == null)
      searchOffset = 0;

    List<Object> page = new List<Object>();
    Integer stop = Math.min(searchOffset + pageSize, searchRows.size());
    for (Integer i = searchOffset; i < stop; i++)
      page.add(searchRows[i]);
    searchOffset = stop;

    Map<String, Object> body = new Map<String, Object>{ 'results' => page };
    if (searchOffset < searchRows.size()) {
      body.put(
        'paging',
        new Map<String, Object>{
          'next' => new Map<String, Object>{
            'after' => String.valueOf(searchOffset)
          }
        }
      );
    }
    res.setStatusCode(200);
    res.setBody(JSON.serialize(body));
    return res;
  }

  /**
   * /batch/read serves three callers, distinguished by their request shape:
   *
   *  - WITH idProperty and a properties list -> the outbound shared-ownership
   *    comparison (batchReadBySfId). Answers from compareProps, keyed by sfId.
   *  - WITH idProperty and no extra properties -> id resolution
   *    (resolveHubSpotIds). Existing behaviour, gated on returnExisting.
   *  - WITHOUT idProperty -> the inbound blank-confirmation pass
   *    (batchReadProperties), keyed by HubSpot id. Answers from
   *    confirmReadProps, which may carry explicit nulls.
   */
  private HttpResponse batchReadResponse(String requestBody, HttpResponse res) {
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    String idProperty = (String) parsed.get('idProperty');
    List<Object> inputs = (List<Object>) parsed.get('inputs');

    if (idProperty == null) {
      confirmReadCallCount++;
      if (failConfirmRead) {
        res.setStatusCode(500);
        res.setBody(
          '{"status":"error","message":"simulated confirm-read failure"}'
        );
        return res;
      }
      List<Object> results = new List<Object>();
      if (inputs != null) {
        for (Object o : inputs) {
          String hsId = String.valueOf(((Map<String, Object>) o).get('id'));
          if (!confirmReadProps.containsKey(hsId))
            continue;
          results.add(
            new Map<String, Object>{
              'id' => hsId,
              'properties' => confirmReadProps.get(hsId)
            }
          );
        }
      }
      res.setStatusCode(200);
      res.setBody(
        JSON.serialize(new Map<String, Object>{ 'results' => results })
      );
      return res;
    }

    if (failCompareRead) {
      res.setStatusCode(500);
      res.setBody(
        '{"status":"error","message":"simulated comparison-read failure"}'
      );
      return res;
    }

    // Comparison read: answer only for sf-ids the test has staged, so a
    // record with no staged HubSpot copy reads as "not in this portal yet".
    if (!compareProps.isEmpty()) {
      List<Object> results = new List<Object>();
      if (inputs != null) {
        for (Object o : inputs) {
          String sfId = String.valueOf(((Map<String, Object>) o).get('id'));
          if (!compareProps.containsKey(sfId))
            continue;
          Map<String, Object> props = new Map<String, Object>(
            compareProps.get(sfId)
          );
          props.put(idProperty, sfId);
          results.add(
            new Map<String, Object>{ 'id' => '99900', 'properties' => props }
          );
        }
      }
      res.setStatusCode(200);
      res.setBody(
        JSON.serialize(new Map<String, Object>{ 'results' => results })
      );
      return res;
    }

    res.setStatusCode(200);
    // Not present -> empty results -> archive is a no-op (success).
    res.setBody(
      returnExisting ? echoResults(requestBody, 0) : '{"results":[]}'
    );
    return res;
  }

  // Record the properties sent per HubSpot id on /batch/update.
  private void captureUpdateProps(String requestBody) {
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    List<Object> inputs = (List<Object>) parsed.get('inputs');
    if (inputs == null)
      return;
    for (Object o : inputs) {
      Map<String, Object> input = (Map<String, Object>) o;
      capturedUpdateProps.put(
        String.valueOf(input.get('id')),
        (Map<String, Object>) input.get('properties')
      );
    }
  }

  // Build a v4 association batch/read response: one result per input from-id.
  // `to` is empty by default (so every desired link is a create); when
  // returnExistingAssociations is set, each from-record already has a stale link
  // to 777001 tagged with both default types, so the diff yields an archive.
  private String echoAssociationRead(String requestBody) {
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    List<Object> inputs = (List<Object>) parsed.get('inputs');
    List<Object> results = new List<Object>();
    if (inputs != null) {
      for (Object o : inputs) {
        String fromId = String.valueOf(((Map<String, Object>) o).get('id'));
        List<Object> tos = new List<Object>();
        if (returnExistingAssociations) {
          tos.add(
            new Map<String, Object>{
              'toObjectId' => '777001',
              'associationTypes' => new List<Object>{
                new Map<String, Object>{
                  'category' => 'HUBSPOT_DEFINED',
                  'typeId' => 279
                },
                new Map<String, Object>{
                  'category' => 'HUBSPOT_DEFINED',
                  'typeId' => 4
                }
              }
            }
          );
        }
        results.add(
          new Map<String, Object>{
            'from' => new Map<String, Object>{ 'id' => fromId },
            'to' => tos
          }
        );
      }
    }
    return JSON.serialize(new Map<String, Object>{ 'results' => results });
  }

  // Build a batch response echoing each input's id as a result carrying that
  // value under the request's OWN idProperty (per-input for upsert, top-level
  // for batch/read), plus a synthetic HubSpot object id. Reading the idProperty
  // from the request keeps the mock generic across objects (contact_id_sf,
  // account_id_sf, ...). `skipFirst` inputs are omitted from results (to
  // simulate per-record failures on 207).
  private String echoResults(String requestBody, Integer skipFirst) {
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    String topIdProp = (String) parsed.get('idProperty');
    List<Object> inputs = (List<Object>) parsed.get('inputs');
    List<Object> results = new List<Object>();
    Integer n = 0;
    if (inputs != null) {
      for (Object o : inputs) {
        if (n >= skipFirst) {
          Map<String, Object> input = (Map<String, Object>) o;
          String idProp = (input.get('idProperty') != null)
            ? (String) input.get('idProperty')
            : topIdProp;
          String sfId = String.valueOf(input.get('id'));
          results.add(
            new Map<String, Object>{
              'id' => '99900' + n,
              'properties' => new Map<String, Object>{ idProp => sfId }
            }
          );
        }
        n++;
      }
    }
    return JSON.serialize(new Map<String, Object>{ 'results' => results });
  }

  // Record the properties actually sent per sfId on a /batch/upsert call, so
  // tests can assert on the parsed payload (e.g. hubspot_owner_id) instead of
  // raw JSON.
  private void captureUpsertProps(String requestBody) {
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      requestBody
    );
    List<Object> inputs = (List<Object>) parsed.get('inputs');
    if (inputs == null)
      return;
    for (Object o : inputs) {
      Map<String, Object> input = (Map<String, Object>) o;
      String sfId = String.valueOf(input.get('id'));
      capturedUpsertProps.put(
        sfId,
        (Map<String, Object>) input.get('properties')
      );
    }
  }
}
