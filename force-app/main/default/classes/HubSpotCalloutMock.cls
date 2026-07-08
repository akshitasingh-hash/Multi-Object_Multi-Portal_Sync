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

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        String endpoint = req.getEndpoint();
        if (throwCallout && endpoint.contains('/batch/')) {
            // Simulate a timeout / connection / auth error at the callout layer.
            throw new CalloutException('simulated callout failure');
        }
        if (failBatch && endpoint.contains('/batch/')) {
            res.setStatusCode(500);
            res.setBody('{"status":"error","message":"simulated failure"}');
            return res;
        }
        if (endpoint.endsWith('/batch/upsert')) {
            if (partialUpsert) {
                // 207 multi-status: echo all inputs except the first (which failed).
                res.setStatusCode(207);
                res.setBody(echoResults(req.getBody(), 1));
            } else {
                // Every input succeeds.
                res.setStatusCode(200);
                res.setBody(echoResults(req.getBody(), 0));
            }
        } else if (endpoint.endsWith('/batch/read')) {
            res.setStatusCode(200);
            // Not present -> empty results -> archive is a no-op (success).
            res.setBody(returnExisting ? echoResults(req.getBody(), 0) : '{"results":[]}');
        } else if (endpoint.endsWith('/batch/archive')) {
            res.setStatusCode(204);
        } else if (endpoint.contains('/search')) {
            res.setStatusCode(200);
            res.setBody(returnExisting ? '{"results":[{"id":"12345"}]}' : '{"results":[]}');
        } else if (req.getMethod() == 'DELETE') {
            res.setStatusCode(204);
        } else {
            // POST create or PATCH update
            res.setStatusCode(200);
            res.setBody('{"id":"12345"}');
        }
        return res;
    }

    // Build a batch response echoing each input's id as a result carrying that
    // value under the request's OWN idProperty (per-input for upsert, top-level
    // for batch/read), plus a synthetic HubSpot object id. Reading the idProperty
    // from the request keeps the mock generic across objects (contact_id_sf,
    // account_id_sf, ...). `skipFirst` inputs are omitted from results (to
    // simulate per-record failures on 207).
    private String echoResults(String requestBody, Integer skipFirst) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
        String topIdProp = (String) parsed.get('idProperty');
        List<Object> inputs = (List<Object>) parsed.get('inputs');
        List<Object> results = new List<Object>();
        Integer n = 0;
        if (inputs != null) {
            for (Object o : inputs) {
                if (n >= skipFirst) {
                    Map<String, Object> input = (Map<String, Object>) o;
                    String idProp = (input.get('idProperty') != null)
                        ? (String) input.get('idProperty') : topIdProp;
                    String sfId = String.valueOf(input.get('id'));
                    results.add(new Map<String, Object>{
                        'id'         => '99900' + n,
                        'properties' => new Map<String, Object>{ idProp => sfId }
                    });
                }
                n++;
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'results' => results });
    }
}
