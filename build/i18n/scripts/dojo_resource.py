#!/usr/bin/env python
# dojo_resource.py
"""
This class enables translation of Dojo resource bundles using gettext format.

Requires polib from http://polib.googlecode.com

Source event definitions are structured as follows:
{
    "MSG_ID1": "This is a message with 1 variable - ${0}.",
    "MSG_ID2": "This is a message with two variables: ${0} and ${1}."
}

Note that this is a deliberately limited subset of the variable substitution
allowed by http://api.dojotoolkit.org/jsdoc/dojo/1.2/dojo.string.substitute

"""
# Copyright 2007 Dan Scott <dscott@laurentian.ca>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

import basel10n
import codecs
import optparse
import polib
import re
import sys
import simplejson
import os.path
import os

class DojoResource (basel10n.BaseL10N):
    """
    This class provides methods for extracting translatable strings from
    Evergreen's Dojo resource bundle files, generating translatable POT files,
    reading translated PO files, and generating an updated Dojo resource bundle
    files with additional or changed strings.
    """

    def __init__(self):
        self.pot = None
        basel10n.BaseL10N.__init__(self)
        self.msgs = {}

    def get_strings(self, source):
        """
        Extracts translatable strings from Evergreen's Dojo resource bundles.
        """
        self.pothead()

        # Avoid generating duplicate entries by keeping track of msgids
        msgids = dict()

	try:
            bundle = simplejson.load(codecs.open(source, encoding='utf-8', mode='r'))
	except ValueError:
	    print("Reading Dojo resource file %s" % (source))
            raise

        for key, value in bundle.iteritems():
            if value in msgids:
                msgids[unicode(value)].occurrences.append((os.path.basename(source), str(key)))
            else:
                poe = polib.POEntry()
                poe.occurrences = [(os.path.basename(source), str(key))]
                poe.msgid = unicode(value)
                msgids[unicode(value)] = poe

        # Now add the POEntries to our POFile
        for poe in msgids.values():
            self.pot.append(poe)

    def create_bundle(self):
        """
        Creates a Dojo resource bundle file based on a translated PO file.
        """

        for entry in self.pot:
            for occurrence in entry.occurrences:
                # Ack. Horrible hack because polib started insisting
                # that occurrences use integers for line numbers. The nerve!
                filename, msgkey = occurrence[0].split('.js');
                if entry.msgstr == '':
                    # No translation available; use the en-US definition
                    self.msgs[msgkey] = entry.msgid
                else:
                    self.msgs[msgkey] = entry.msgstr

def main():
    """
    Determine what action to take
    """
    opts = optparse.OptionParser()
    opts.add_option('-p', '--pot', action='store', \
        help='Create a POT file from the specified Dojo resource bundle file', \
        metavar='FILE')
    opts.add_option('-c', '--create', action='store', \
        help='Create a Dojo resource bundle file from a translated PO FILE', \
        metavar='FILE')
    opts.add_option('-o', '--output', dest='outfile', \
        help='Write output to FILE (defaults to STDOUT)', metavar='FILE')
    (options, args) = opts.parse_args()

    pot = DojoResource()

    # Generate a new POT file from the Dojo resource bundle file
    if options.pot:
        pot.get_strings(options.pot)
        if options.outfile:
            if not os.path.exists(os.path.dirname(options.outfile)):
                os.makedirs(os.path.dirname(options.outfile))
            pot.savepot(options.outfile)
        else:
            sys.stdout.write(pot.pot.__str__())

    # Generate an Dojo resource bundle file from a PO file
    elif options.create:
        pot.loadpo(options.create)
        pot.create_bundle()
        if options.outfile:
            if not os.path.exists(os.path.dirname(options.outfile)):
                os.makedirs(os.path.dirname(options.outfile))
            outfile = codecs.open(options.outfile, encoding='utf-8', mode='w')
            simplejson.dump(pot.msgs, outfile, indent=4)
        else:
            print(simplejson.dumps(pot.msgs, indent=4))

    # No options were recognized - print help and bail
    else:
        opts.print_help()

if __name__ == '__main__':
    main()
