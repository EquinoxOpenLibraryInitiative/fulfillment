/* Core Sevice - egAuth
 *
 * Manages login and auth session retrieval
 *
 * Angular cookies are still fairly primitive.  
 * In particular, you can't set the path.
 * https://github.com/angular/angular.js/issues/1786
 */

angular.module('egCoreMod')

.constant('EG_AUTH_COOKIE', 'ses')

.factory('egAuth', 
       ['$q','$cookies','$timeout','$location','$window','egNet','EG_AUTH_COOKIE',
function($q,  $cookies,  $timeout,  $location,  $window,  egNet,  EG_AUTH_COOKIE) {

    var service = {
        user : function() {
            return this._user;
        },
        token : function() {
            return $cookies[EG_AUTH_COOKIE];
        }
    };

    /* Returns a promise, which is resolved if valid
     * authtoken is found, otherwise rejected */
    service.testAuthToken = function() {
        var deferred = $q.defer();
        var token = service.token();

        if (token) {
            egNet.request(
                'open-ils.auth',
                'open-ils.auth.session.retrieve', token).then(
                function(user) {
                    if (user && user.classname) {
                        service._user = user;
                        deferred.resolve();
                    } else {
                        delete $cookies[EG_AUTH_COOKIE]; 
                        deferred.reject();
                    }
                }
            );

        } else {
            deferred.reject();
        }

        return deferred.promise;
    };

    /**
     * Returns a promise, which is resolved on successful 
     * login and rejected on failed login.
     */
    service.login = function(args) {
        var deferred = $q.defer();
        egNet.request(
            'open-ils.auth',
            'open-ils.auth.authenticate.init', args.username).then(
            function(seed) {
                args.password = hex_md5(seed + hex_md5(args.password))
                egNet.request(
                    'open-ils.auth',
                    'open-ils.auth.authenticate.complete', args).then(
                    function(evt) {
                        if (evt.textcode == 'SUCCESS') {
                            // Use js.cookies.js in order to set the cookie path to /
                            Cookies.set(EG_AUTH_COOKIE, evt.payload.authtoken);
                            deferred.resolve();
                        } else {
                            console.error('login failed ' + js2JSON(evt));
                            deferred.reject();
                        }
                    }
                )
            }
        );

        return deferred.promise;
    };

    service.logout = function() {
        console.debug('egAuth.logout()');
        if (service.token()) {
            egNet.request(
                'open-ils.auth',
                'open-ils.auth.session.delete',
                service.token()
            ); // fire and forget
        }
        delete $cookies[EG_AUTH_COOKIE];
        service._user = null;
    };

    return service;
}]);

