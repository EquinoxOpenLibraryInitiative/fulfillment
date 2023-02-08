/**
 * Free-floating controller which can be used by any app.
 */
function NavCtrl($scope, egStartup, egAuth, egEnv) {

    $scope.logout = function() {
        egAuth.logout();
        return true;
    };

    /**
     * Two important things happening here.
     *
     * 1. Since this is a standalone controller, which may execute at
     * any time during page load, we have no gaurantee that needed
     * startup actions, session retrieval being the main one, have taken
     * place yet. So we kick off the startup chain ourselves and run
     * actions when it's done. Note this does not mean startup runs
     * multiple times. If it's already started, we just pick up the
     * existing startup promise.
     *
     * 2. We are updating the $scope asynchronously, but since it's
     * done inside a promise resolver, another $digest() loop will
     * run and pick up our changes.  No $scope.$apply() needed.
     */
    egStartup.go().then(
        function() {

            // login page will not have a cached user
            if (!egAuth.user()) return;

            $scope.username = egAuth.user().usrname();

            // TODO: move workstation into egAuth
            if (egEnv.aws) {
                $scope.workstation = 
                    egEnv.aws.map[egAuth.user().wsid()].name();
            }
        }
    );
}

// minify-safe dependency injection
NavCtrl.$inject = ['$scope', 'egStartup', 'egAuth', 'egEnv'];
