/**
 * Core Service - egIDL
 *
 * IDL parser
 * usage:
 *  var aou = new egIDL.aou();
 *  var fullIDL = egIDL.classes;
 *
 *  IDL TODO:
 *
 * 1. selector field only appears once per class.  We could save
 *    a lot of IDL (network) space storing it only once at the 
 *    class level.
 * 2. we don't need to store array_position in /IDL2js since it
 *    can be derived at parse time.  Ditto saving space.
 */
angular.module('egCoreMod')

.factory('egIDL', ['$window', function($window) {

    var service = {};

    service.parseIDL = function() {
        console.debug('egIDL.parseIDL()');

        // retain a copy of the full IDL within the service
        service.classes = $window._preload_fieldmapper_IDL;

        // original, global reference no longer needed
        $window._preload_fieldmapper_IDL = null;

        /**
         * Creates the class constructor and getter/setter
         * methods for each IDL class.
         */
        function mkclass(cls, fields) {

            service[cls] = function(seed) {
                this.a = seed || [];
                this.classname = cls;
                this._isfieldmapper = true;
            }

            /** creates the getter/setter methods for each field */
            angular.forEach(fields, function(field, idx) {
                service[cls].prototype[fields[idx].name] = function(n) {
                    if (arguments.length==1) this.a[idx] = n;
                    return this.a[idx];
                }
            });

            // global class constructors required for JSON_v1.js
            $window[cls] = service[cls]; 
        }

        for (var cls in service.classes) 
            mkclass(cls, service.classes[cls].fields);
    };

    return service;
}]);

