/**
 * App to drive the base page. 
 * Login Form
 * Splash Page
 */

angular.module('egHome', ['ngRoute', 'egCoreMod', 'egUiMod'])

.config(function($routeProvider, $locationProvider) {

    /**
     * Route resolvers allow us to run async commands
     * before the page controller is instantiated.
     */
    var resolver = {delay : function(egStartup) {return egStartup.go()}};

    $routeProvider.when('/login', {
        templateUrl: './t_login',
        controller: 'LoginCtrl',
        resolve : {delay : function(egStartup, egAuth) {
            // hack for now to kill the base ses cookie where sub-path
            // apps were unable to remove it.  See note at the top of 
            // services/auth.js about angular cookies and paths.
            egAuth.logout();
            return egStartup.go();
        }}
    });

    // default page 
    $routeProvider.otherwise({
        templateUrl : './t_splash',
        controller : 'SplashCtrl',
        resolve : resolver
    });

    // HTML5 pushstate support
    $locationProvider.html5Mode(true);
})

/**
 * Login controller.  
 * Reads the login form and submits the login request
 */
.controller('LoginCtrl', 
    /* inject services into our controller.  Spelling them
     * out like this allows the auto-magic injector to work
     * even if the code has been minified */
    ['$scope', '$location', '$window', 'egAuth',
    function($scope, $location, $window, egAuth) {
        $scope.focusMe = true;

        // for now, workstations may be passed in via URL param
        $scope.args = {workstation : $location.search().ws};

        $scope.login = function(args) {
            args.type = 'staff';
            $scope.loginFailed = false;

            egAuth.login(args).then(
                function() { 
                    // after login, send the user back to the originally
                    // requested page or, if none, the home page.
                    // TODO: this is a little hinky because it causes 2 
                    // redirects if no route_to is defined.  Improve.
                    $window.location.href = 
                        $location.search().route_to || 
                        $location.path('/').absUrl()
                },
                function() {
                    $scope.args.password = '';
                    $scope.loginFailed = true;
                    $scope.focusMe = true;
                }
            );
        }
    }
])

/**
 * Splash page dynamic content.
 */
.controller('SplashCtrl', ['$scope',
    function($scope) {
        console.log('SplashCtrl');
    }
]);

