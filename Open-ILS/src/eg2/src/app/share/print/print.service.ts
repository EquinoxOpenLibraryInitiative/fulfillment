import {Injectable, EventEmitter, TemplateRef} from '@angular/core';
import {tap} from 'rxjs/operators';
import {StoreService} from '@eg/core/store.service';
import {LocaleService} from '@eg/core/locale.service';
import {AuthService} from '@eg/core/auth.service';

declare var js2JSON: (jsThing: any) => string;
declare var OpenSRF;

const PRINT_TEMPLATE_PATH = '/print_template';

export interface PrintRequest {
    template?: TemplateRef<any>;
    templateName?: string;
    templateOwner?: number; // org unit ID, follows ancestors
    templateId?: number; // useful for testing templates
    contextData?: any;
    text?: string;
    printContext: string;
    contentType?: string; // defaults to text/html
    showDialog?: boolean;
}

export interface PrintTemplateResponse {
    contentType: string;
    content: string;
}

@Injectable()
export class PrintService {

    onPrintRequest$: EventEmitter<PrintRequest>;

    constructor(
        private locale: LocaleService,
        private auth: AuthService,
        private store: StoreService
    ) {
        this.onPrintRequest$ = new EventEmitter<PrintRequest>();
    }

    print(printReq: PrintRequest) {
        this.onPrintRequest$.emit(printReq);
    }

    reprintLast() {
        const prev = this.store.getLocalItem('eg.print.last_printed');

        if (prev) {
            const req: PrintRequest = {
                text: prev.content,
                printContext: prev.context || 'default',
                contentType: prev.content_type || 'text/html',
                showDialog: Boolean(prev.show_dialog)
            };

            this.print(req);
        }
    }

    compileRemoteTemplate(printReq: PrintRequest): Promise<PrintTemplateResponse> {

        const formData: FormData = new FormData();

        formData.append('ses', this.auth.token());
        if (printReq.templateName) {
            formData.append('template_name', printReq.templateName);
        }
        if (printReq.templateId) {
            formData.append('template_id', '' + printReq.templateId);
        }
        if (printReq.templateOwner) {
            formData.append('template_owner', '' + printReq.templateOwner);
        }
        formData.append('template_data', js2JSON(printReq.contextData));
        formData.append('template_locale', this.locale.currentLocaleCode());

        // Sometimes we want to know the time zone of the browser/user,
        // regardless of any org unit settings.
        if (OpenSRF.tz) {
            formData.append('client_timezone', OpenSRF.tz);
        }

        return new Promise((resolve, reject) => {
            const xhttp = new XMLHttpRequest();
            xhttp.onreadystatechange = function() {
                if (this.readyState === 4) {
                    if (this.status === 200) {
                        resolve({
                            content: xhttp.responseText,
                            contentType: this.getResponseHeader('content-type')
                        });
                    } else if (this.status === 404) {
                        console.error('No active template found: ', printReq);
                        reject({notFound: true});
                    }
                    reject({});
                }
            };
            xhttp.open('POST', PRINT_TEMPLATE_PATH, true);
            xhttp.send(formData);
        });

    }
}

