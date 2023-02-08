/**
 * Core Service - egNet
 *
 * Promise wrapper for OpenSRF network calls.
 * http://docs.angularjs.org/api/ng.$q
 *
 * promise.notify() is called with each streamed response.
 *
 * promise.resolve() is called when the request is complete 
 * and passes as its value the response received from the 
 * last call to onresponse().
 *
 * Example: Call with one response and no error checking:
 *
 * egNet.request(service, method, param1, param2).then(
 *      function(data) { console.log(data) });
 *
 * Example: capture streaming responses, error checking
 *
 * egNet.request(service, method, param1, param2).then(
 *      function(data) { console.log('all done') },
 *      function(err)  { console.log('error: ' + err) },
 *      functoin(data) { console.log('received stream response ' + data) }
 *  );
 */

angular.module('egCoreMod')

.factory('egNet', ['$q', function($q) {

    return {
        request : function(service, method) {
            var last;
            var deferred = $q.defer();
            var params = Array.prototype.slice.call(arguments, 2);
            new OpenSRF.ClientSession(service).request({
                async  : true,
                method : method,
                params : params,
                oncomplete : function() {
                    deferred.resolve(last ? last.content() : null);
                },
                onresponse : function(r) {
                    if (last = r.recv())
                        deferred.notify(last.content());
                },
                onerror : function(msg) {
                    // 'msg' currently tells us very little, so don't 
                    // bother JSON-ifying it, since there is the off
                    // chance that JSON-ification could fail, e.g if 
                    // the object has circular refs.
                    console.error(method + 
                        ' (' + params + ')  failed.  See server logs.');
                    deferred.reject(msg);
                }
            }).send();

            return deferred.promise;
        }
    };
}]);
