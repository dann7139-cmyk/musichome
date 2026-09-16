import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';
import { getLogoDataUri, brandHeaderHtml, BRAND_HEADER_CSS } from './pdfBranding';

/**
 * PDF de "Demanda entre países" (sql/657/658)  -  documento con logo y marca
 * de Daricefy, pensado para servir de prueba de demanda real ante un
 * trámite de visa de trabajo. Fondo claro y tipografía neutra a propósito
 * (nada de la estética oscura de la app)  -  es un documento formal, no una
 * pantalla de la app.
 */

export interface CrossBorderDetailItem {
  quote_id: string;
  was_blocked: boolean;
  client_name: string | null;
  client_phone: string | null;
  event_date: string;
  event_time: string | null;
  event_address: string | null;
  event_municipio: string | null;
  event_estado: string | null;
  created_at: string;
}

const esc = (v: unknown): string =>
  String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const fecha = (d?: string | null) =>
  d ? new Date(d).toLocaleDateString('es-MX', { day: '2-digit', month: 'long', year: 'numeric' }) : ' - ';

export async function exportCrossBorderPdf(params: {
  groupName: string;
  groupCountry: string;
  eventCountry: string;
  items: CrossBorderDetailItem[];
}): Promise<void> {
  const { groupName, groupCountry, eventCountry, items } = params;

  const logoDataUri = await getLogoDataUri();

  const totalBlocked = items.filter(i => i.was_blocked).length;
  const totalFulfilled = items.length - totalBlocked;

  const rows = items.map((d, i) => `
    <tr>
      <td class="num">${i + 1}</td>
      <td>${esc(d.client_name ?? 'Sin nombre registrado')}</td>
      <td>${esc(d.client_phone ?? ' - ')}</td>
      <td>${esc(fecha(d.event_date))}${d.event_time ? '  |  ' + esc(d.event_time) : ''}</td>
      <td>${esc([d.event_address, d.event_municipio, d.event_estado].filter(Boolean).join(', '))}</td>
      <td><span class="tag ${d.was_blocked ? 'tag-blocked' : 'tag-ok'}">${d.was_blocked ? 'Bloqueada  -  sin visa' : 'Cumplida'}</span></td>
    </tr>`).join('');

  const html = `
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
    color: #1a1a1a; margin: 0; padding: 36px 40px;
    font-size: 12px; line-height: 1.5;
  }
  ${BRAND_HEADER_CSS}

  h1 { font-size: 17px; margin: 0 0 4px; color: #0a0a0a; }
  .subtitle { font-size: 12px; color: #555; margin-bottom: 18px; }
  .route { font-weight: 600; color: #0a0a0a; }

  .summary { display: flex; gap: 24px; margin-bottom: 20px; }
  .summary-box { border: 1px solid #e0e0e0; border-radius: 8px; padding: 10px 16px; text-align: center; }
  .summary-box .n { font-size: 20px; font-weight: 800; }
  .summary-box .l { font-size: 10px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .n-blocked { color: #D32F2F; }
  .n-ok { color: #00A344; }

  table { width: 100%; border-collapse: collapse; margin-top: 6px; }
  th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: 0.4px; color: #666; border-bottom: 2px solid #e0e0e0; padding: 8px 6px; }
  td { padding: 9px 6px; border-bottom: 1px solid #eee; font-size: 11.5px; vertical-align: top; }
  td.num { color: #999; width: 24px; }

  .tag { display: inline-block; padding: 3px 9px; border-radius: 20px; font-size: 10px; font-weight: 600; }
  .tag-blocked { background: #FDECEA; color: #C62828; }
  .tag-ok { background: #E3F7EA; color: #00843D; }

  .footer { margin-top: 28px; padding-top: 14px; border-top: 1px solid #e0e0e0; font-size: 9.5px; color: #666; }
</style>
</head>
<body>
  ${brandHeaderHtml(logoDataUri, 'Reporte de demanda entre países')}

  <h1>${esc(groupName)}</h1>
  <div class="subtitle">Ruta: <span class="route">${esc(groupCountry)}  ->  ${esc(eventCountry)}</span>  |  Generado el ${esc(new Date().toLocaleDateString('es-MX', { day: '2-digit', month: 'long', year: 'numeric' }))}</div>

  <div class="summary">
    <div class="summary-box"><div class="n">${items.length}</div><div class="l">Total de solicitudes</div></div>
    <div class="summary-box"><div class="n n-blocked">${totalBlocked}</div><div class="l">Bloqueadas sin visa</div></div>
    <div class="summary-box"><div class="n n-ok">${totalFulfilled}</div><div class="l">Cumplidas</div></div>
  </div>

  <table>
    <thead>
      <tr>
        <th></th>
        <th>Cliente</th>
        <th>Teléfono</th>
        <th>Fecha del evento</th>
        <th>Dirección</th>
        <th>Estado</th>
      </tr>
    </thead>
    <tbody>
      ${rows}
    </tbody>
  </table>

  <div class="footer">
    Documento generado automáticamente por Daricefy a partir de las solicitudes reales recibidas en la plataforma.
    Cada fila corresponde a una solicitud de cotización enviada por un cliente para un evento fuera del país del proveedor.
  </div>
</body>
</html>`;

  const { uri } = await Print.printToFileAsync({ html, base64: false });

  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(uri, {
      mimeType: 'application/pdf',
      dialogTitle: `${groupName}  -  ${groupCountry} a ${eventCountry}`,
      UTI: 'com.adobe.pdf',
    });
  }
}
