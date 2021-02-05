dump('entering util/barcode.js\n');

if (typeof util == 'undefined') var util = {};
util.barcode = {};

util.barcode.EXPORT_OK    = [ 
    'check', 'checkdigit',
];
util.barcode.EXPORT_TAGS    = { ':all' : util.barcode.EXPORT_OK };

util.barcode.check = function(bc) {
    if (bc != Number(bc)) return false;
    bc = bc.toString();
    // "16.00" == Number("16.00"), but the . is bad.
    // Throw out any barcode that isn't just digits
    if (bc.search(/\D/) != -1) return false;
    var last_digit = bc.substr(bc.length-1);
    var stripped_barcode = bc.substr(0,bc.length-1);
    return util.barcode.checkdigit(stripped_barcode).toString() == last_digit;
}

util.barcode.checkdigit = function(bc) {
    var reverse_barcode = bc.toString().split('').reverse();
    var check_sum = 0; var multiplier = 2;
    for (var i = 0; i < reverse_barcode.length; i++) {
        var digit = reverse_barcode[i];
        var product = digit * multiplier; product = product.toString();
        var temp_sum = 0;
        for (var j = 0; j < product.length; j++) {
            temp_sum += Number( product[j] );
        }
        check_sum += Number( temp_sum );
        multiplier = ( multiplier == 2 ? 1 : 2 );
    }
    check_sum = check_sum.toString();
    var next_multiple_of_10 = (check_sum.match(/(\d*)\d$/)[1] * 10) + 10;
    var check_digit = next_multiple_of_10 - Number(check_sum); if (check_digit == 10) check_digit = 0;
    return check_digit;
}

dump('exiting util/barcode.js\n');
