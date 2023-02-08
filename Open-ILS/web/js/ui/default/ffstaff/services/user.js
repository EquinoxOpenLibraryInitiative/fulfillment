/** 
 * Service for fetching fleshed user objects.
 * The last user retrieved is kept until replaced by a new user.
 */

angular.module('egUserMod', ['egCoreMod'])

.factory('egUser', 
       ['$q','$timeout','egNet','egAuth','egOrg',
function($q,  $timeout,  egNet,  egAuth,  egOrg) {

    var service = {_user : null};
    service.get = function(userId) {
        var deferred = $q.defer();

        var last = sevice._user;
        if (last && last.id() == userId) {
            return $q.when(last);

        } else {

            egNet.request(
                'open-ils.actor',
                'open-ils.actor.user.fleshed.retrieve',
                egAuth.token(), userId).then(
                function(user) {
                    if (user && user.classname == 'au') {
                        service._user = user;
                        deferred.resolve(user);
                    } else {
                        service._user = null;
                        deferred.reject(user);
                    }
                }
            );
        }

        return deferred.promise;
    };

    /*
     * Returns the full list of org unit objects at which the currently
     * logged in user has the selected permissions.
     * @permList - list or string.  If a list, the response object is a
     * hash of perm => orgList maps.  If a string, the response is the
     * org list for the requested perm.
     */
    service.hasPermAt = function(permList) {
        var deferred = $q.defer();
        var isArray = true;
        if (!angular.isArray(permList)) {
            isArray = false;
            permList = [permList];
        }
        // as called, this method will return the top-most org unit of the
        // sub-tree at which this user has the selected permission.
        // From there, flesh the descendant orgs locally.
        egNet.request(
            'open-ils.actor',
            'open-ils.actor.user.has_work_perm_at.batch',
            egAuth.token(), permList
        ).then(function(resp) {
            var answer = {};
            angular.forEach(permList, function(perm) {
                var all = [];
                angular.forEach(resp[perm], function(oneOrg) {
                    all = all.concat(egOrg.descendants(oneOrg));
                });
                answer[perm] = all;
            });
            if (!isArray) answer = answer[permList[0]];
            deferred.resolve(answer);
        });
        return deferred.promise;
    };

    return service;
}]);

