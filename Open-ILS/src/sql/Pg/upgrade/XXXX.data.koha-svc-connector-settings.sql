BEGIN;

INSERT INTO config.org_unit_setting_type ( name, label, description, datatype ) VALUES
(   'ff.remote.connector.extra.svc.host',
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.host', 'LAI: Connector svc API host (for Koha)', 'coust', 'label'),
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.host', 'Hostname of the Koha /svc API (usually the staff interface)', 'coust', 'description'),
    'string'),
(   'ff.remote.connector.extra.svc.user',
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.user', 'LAI: Connector svc API user (for Koha)', 'coust', 'label'),
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.user', 'User to be used to log into the Koha /svc API', 'coust', 'description'),
    'string'),
(   'ff.remote.connector.extra.svc.password',
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.password', 'LAI: Connector svc API password (for Koha)', 'coust', 'label'),
    oils_i18n_gettext( 'ff.remote.connector.extra.svc.password', 'Password to be used to log into the Koha /svc API', 'coust', 'description'),
    'string');

COMMIT:
