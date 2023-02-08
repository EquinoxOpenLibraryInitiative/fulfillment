/** 
 * Service for generating list management objects.
 * Each object tracks common list attributes like limit, offset, etc.,
 * A ListManager is not responsible for collecting data, it's only
 * there to allow controllers to have a known consistent API
 * for manage list-related information.
 *
 * The service exports a single attribute, which instantiates
 * a new ListManager object.  Controllers using ListManagers
 * are responsible for providing their own route persistence.
 *
 * var list = egList.create();
 * if (list.hasNextPage()) { ... }
 *
 */

angular.module('egListMod', ['egCoreMod'])

.factory('egList', function() {

    function ListManager(args) {
        var self = this;
        this.limit = 25;
        this.offset = 0;
        this.sort = null;
        this.totalCount = 0;

        // attribute on each item in our items list which
        // refers to its unique identifier value
        this.indexField = 'index';

        // true if the index field name refers to a 
        // function instead of an object attribute
        this.indexFieldAsFunction = false;

        // per-page list of items
        this.items = [];

        // collect any defaults passed in
        if (args) angular.forEach(args, 
            function(val, key) {self[key] = val});

        // sorted list of all available display columns
        // a column takes form of (at minimum) {name : name, label : label}
        this.allColumns = [];

        // {name => true} map of visible columns
        this.displayColumns = {}; 

        // {index => true} map of selected rows
        this.selected = {};

        this.indexValue = function(item) {
            if (this.indexFieldAsFunction) {
                return item[this.indexField]();
            } else {
                return item[this.indexField];
            }
        }

        // returns item objects
        this.selectedItems = function() {
            var items = [];
            angular.forEach(
                this.items,
                function(item) {
                    if (self.selected[self.indexValue(item)])
                        items.push(item);
                }
            );
            return items;
        }

        // remove an item from the items list
        this.removeItem = function(index) {
            angular.forEach(this.items, function(item, idx) {
                if (self.indexValue(item) == index)
                    self.items.splice(idx, 1);
            });
            delete this.selected[index];
        }

        this.count = function() { return this.items.length }

        this.reset = function() {
            this.offset = 0;
            this.totalCount = 0;
            this.items = [];
            this.selected = {};
        }

        // prepare to draw a new page of data
        this.resetPageData = function() {
            this.items = [];
            this.selected = {};
        }

        this.showAllColumns = function() {
            angular.forEach(this.allColumns, function(field) {
                self.displayColumns[field.name] = true;
            });
        }

        this.hideAllColumns = function() {
            angular.forEach(this.allColumns, function(field) {
                delete self.displayColumns[field.name]
            });
        }

        // selects one row after deselecting all of the others
        this.selectOne = function(index) {
            this.deselectAll();
            this.selected[index] = true;
        }

        // selects or deselects a row, without affecting the others
        this.toggleOneSelection = function(index) {
            if (this.selected[index]) {
                delete this.selected[index];
            } else {
                this.selected[index] = true;
            }
        }

        // selects all visible rows
        this.selectAll = function() {
            angular.forEach(this.items, function(item) {
                self.selected[self.indexValue(item)] = true
            });
        }

        // if all are selected, deselect all, otherwise select all
        this.toggleSelectAll = function() {
            if (Object.keys(this.selected).length == this.items.length) {
                this.deselectAll();
            } else {
                this.selectAll();
            }
        }

        // deselects all visible rows
        this.deselectAll = function() {
            this.selected = {};
        }

        this.defaultColumns = function(list) {
            // set the display=true value for the selected columns
            angular.forEach(list, function(name) {
                self.displayColumns[name] = true
            });

            // default columns may be provided before we 
            // know what our columns are.  Save them for later.
            this._defaultColumns = list;

            // setColumns we rearrange the allCollums 
            // list based on the content of this._defaultColums
            if (this.allColumns.length) 
                this.setColumns(this.allColumns);
        }

        this.setColumns = function(list) {
            if (this._defaultColumns) {
                this.allColumns = [];

                // append the default columns to the front of
                // our allColumnst list.  Any remaining columns
                // are plopped onto the end.
                angular.forEach(
                    this._defaultColumns,
                    function(name) {
                        var foundIndex;
                        angular.forEach(list, function(f, idx) {
                            if (f.name == name) {
                                self.allColumns.push(f);
                                foundIndex = idx;
                            }
                        });
                        list.splice(foundIndex, 1);
                    }
                );
                this.allColumns = this.allColumns.concat(list);
                delete this._defaultColumns;

            } else {
                this.allColumns = list;
            }
        }

        this.onFirstPage = function() { 
            return this.offset == 0;
        }

        this.hasNextPage = function() {
            // we have less data than requested, there must
            // not be any more pages
            if (this.items.length < this.limit) return false;

            // if the total count is not known, assume that a full
            // page of data implies more pages are available.
            if (!this.totalCount) return true;

            // we have a full page of data, but is there more?
            return this.totalCount > (this.offset + this.items.length);
        }

        this.incrementPage = function() {
            this.offset += this.limit;
        }

        this.decrementPage = function() {
            if (this.offset < this.limit) {
                this.offset = 0;
            } else {
                this.offset -= this.limit;
            }
        }
    }

    return {
        create : function(args) { 
            return new ListManager(args) 
        }
    };
});

