dump('entering util/money.js\n');

if (typeof util == 'undefined') var util = {};
util.money = {};

util.money.EXPORT_OK    = [ 
    'sanitize', 'dollars_float_to_cents_integer', 'cents_as_dollars'
];
util.money.EXPORT_TAGS    = { ':all' : util.money.EXPORT_OK };

util.money.dollars_float_to_cents_integer = function( money ) {
    try {
        if (money == '' || money == null || money == undefined) money = 0;
        // careful to avoid fractions of pennies
        var negative; negative = money.toString().match(/-/) ? -1 : 1;
        var money_s = money.toString().replace(/[^\.\d]/g, '');
        var marray = money_s.split(".");
        var dollars = marray[0];
        var cents = marray[1];
        try {
            if (cents.length < 2) {
                cents = cents + '0';
            }
        } catch(E) {
        }
        try {
            if (cents.length > 2) {
                dump("util.money: We don't round money\n");
                cents = cents.substr(0,2);
            }
        } catch(E) {
        }
        var total = 0;
        try {
            if (Number(cents)) total += Number(cents);
        } catch(E) {
        }
        try {
            if (Number(dollars)) total += (Number(dollars) * 100);
        } catch(E) {
        }
        return total * negative;    
    } catch(E) {
        alert('util.money.dollars_float_to_cents_integer:\n' + E);
    }
}

util.money.cents_as_dollars = function( cents ) {
    try {
        if (cents == '' || cents == null || cents == undefined) cents = 0;
        var negative; negative = cents.toString().match(/-/) ? '-' : '';
        cents = cents.toString().replace(/[^\.\d]/g, ''); 
        if (cents.match(/\./)) cents = util.money.dollars_float_to_cents_integer( cents ).toString();
        try {
            switch( cents.length ) {
                case 0: cents = '000'; break;
                case 1: cents = '00' + cents; break;
            }
        } catch(E) {
        }
        return negative + cents.substr(0,cents.length-2) + '.' + cents.substr(cents.length - 2);
    } catch(E) {
        alert('util.money.cents_as_dollars:\n' + E);
    }
}

util.money.sanitize = function( money ) {
    return util.money.cents_as_dollars( util.money.dollars_float_to_cents_integer( money ) );
}


dump('exiting util/money.js\n');
