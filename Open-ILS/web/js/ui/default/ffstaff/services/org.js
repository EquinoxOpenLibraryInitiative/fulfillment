/**
 * Core Service - egOrg
 *
 * TODO: more docs
 */
angular.module('egCoreMod')

.factory('egOrg', ['egEnv', 'egAuth', 'egPCRUD',
function(egEnv, egAuth, egPCRUD) { 

    var service = {};

    service.get = function(node_or_id) {
        if (typeof node_or_id == 'object')
            return node_or_id;
        return egEnv.aou.map[node_or_id];
    };

    service.list = function() {
        return egEnv.aou.list;
    };

    service.ancestors = function(node_or_id) {
        var node = service.get(node_or_id);
        if (!node) return [];
        var nodes = [node];
        while( (node = service.get(node.parent_ou())))
            nodes.push(node);
        return nodes;
    };

    service.descendants = function(node_or_id) {
        var node = service.get(node_or_id);
        if (!node) return [];
        var nodes = [];
        function descend(n) {
            nodes.push(n);
            angular.forEach(n.children(), descend);
        }
        descend(node);
        return nodes;
    }

    service.fullPath = function(node_or_id) {
        return service.ancestors(node_or_id).concat(
          service.descendants(node_or_id).slice(1));
    }

    return service;
}]);
 
