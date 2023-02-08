/**
 * Core Service - egStartup
 *
 * Coordinates all startup routines and consolidates them into
 * a single startup promise.  Startup can be launched from multiple
 * controllers, etc., but only one startup routine will be run.
 *
 * If no valid authtoken is found, startup will exit early and 
 * change the page href to the login page.  Otherwise, the global
 * promise returned by startup.go() will be resolved after all
 * async data is arrived.
 */

angular.module('egCoreMod')

.factory('egStartup', 
       ['$q','$rootScope','$location','$window','egIDL','egAuth','egEnv',
function($q,  $rootScope,  $location,  $window,  egIDL,  egAuth,  egEnv) {

    return {
        promise : null,
        go : function () {
            if (this.promise) {
                // startup already started, return our existing promise
                return this.promise;
            } 

            // create a new promise and fire off startup
            var deferred = $q.defer();
            this.promise = deferred.promise;

            // IDL parsing is sync.  No promises required
            egIDL.parseIDL();
            egAuth.testAuthToken().then(

                // testAuthToken resolved
                function() { 
                    egEnv.load().then(
                        function() { deferred.resolve() }, 
                        function() { 
                            deferred.reject('egEnv did not resolve')
                        }
                    );
                },

                // testAuthToken rejected
                function() { 
                    console.log('egAuth found no valid authtoken');
                    if ($location.path() == '/login') {
                        console.debug('egStartup resolving without authtoken on /login');
                        deferred.resolve();
                    } else {
                        // TODO: this is a little hinky because it causes 2 redirects.
                        // the first is the oh-so-convenient call to $location.path(),
                        // the second is the final href change.
                        $window.location.href = $location
                            .path('/login')
                            .search({route_to : 
                                $window.location.pathname + $window.location.search})
                            .absUrl();
                    }
                }
            );

            return this.promise;
        }
    };
}]);

