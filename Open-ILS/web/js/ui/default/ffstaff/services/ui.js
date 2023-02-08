/**
  * UI tools and directives.
  */
angular.module('egUiMod', [])


/**
 * <input focus-me="iAmOpen"/>
 * $scope.iAmOpen = true;
 */
.directive('focusMe', 
['$timeout', '$parse', 
function($timeout, $parse) {
    return {
        link: function(scope, element, attrs) {
            var model = $parse(attrs.focusMe);
            scope.$watch(model, function(value) {
                if(value === true) 
                    $timeout(function() {element[0].focus()});
            });
            element.bind('blur', function() {
                scope.$apply(model.assign(scope, false));
            })
        }
    };
}])

// <input select-me="iWantToBeSelected"/>
// $scope.iWantToBeSelected = true;
.directive('selectMe', 
['$timeout', '$parse', 
function($timeout, $parse) {
    return {
        link: function(scope, element, attrs) {
            var model = $parse(attrs.focusMe);
            scope.$watch(model, function(value) {
                if(value === true) 
                    $timeout(function() {element[0].select()});
            });
            element.bind('blur', function() {
                scope.$apply(model.assign(scope, false));
            })
        }
    };
}]);
