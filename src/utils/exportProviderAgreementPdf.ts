import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';
import { getLogoDataUri, brandHeaderHtml, BRAND_HEADER_CSS } from './pdfBranding';

/**
 * Acuerdo de Proveedor de Servicios — documento imprimible para firma
 * física (docs/legal_provider_liability_draft.md, sección 4). Texto
 * legal EXACTO acordado ahí — no es asesoría legal, es un borrador para
 * revisión de un abogado real antes de depender de él en una demanda.
 *
 * Es estático (mismo texto para cualquier proveedor) — se llena a mano:
 * nombre, categoría, fecha y firma del proveedor, y firma de Daricefy.
 * Fecha y firma van en líneas SEPARADAS a propósito (pedido real).
 */

const BASE_CSS = `
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
    color: #1a1a1a; margin: 0; padding: 36px 40px;
    font-size: 12px; line-height: 1.55;
  }
  ${BRAND_HEADER_CSS}
  .doc-title { font-size: 11px; color: #666; margin-top: 2px; }

  h1 { font-size: 18px; margin: 4px 0 4px; color: #0a0a0a; text-align: center; }
  .intro { font-size: 11.5px; color: #444; margin-bottom: 16px; }

  h2 { font-size: 12.5px; text-transform: uppercase; letter-spacing: 0.4px; color: #00A344; border-bottom: 2px solid #e6f7ec; padding-bottom: 5px; margin: 20px 0 10px; }
  h3 { font-size: 12px; color: #0a0a0a; margin: 14px 0 4px; }

  ol { margin: 0; padding-left: 18px; }
  ol li { margin-bottom: 8px; font-size: 11.5px; }

  .annex { border: 1px solid #eee; border-radius: 8px; padding: 10px 14px; margin-bottom: 10px; background: #fafafa; }
  .annex b { color: #0a0a0a; }
  .annex p { margin: 4px 0 0; font-size: 11px; color: #333; }

  .sign-block { margin-top: 34px; page-break-inside: avoid; }
  .sign-row { display: flex; gap: 30px; margin-top: 26px; }
  .sign-col { flex: 1; }
  .fill-line { border-bottom: 1px solid #999; height: 30px; }
  .fill-label { font-size: 10px; color: #555; margin-top: 3px; text-transform: uppercase; letter-spacing: 0.3px; font-weight: 600; }
  .sign-title { font-size: 11.5px; font-weight: 700; color: #0a0a0a; margin-bottom: 10px; }

  .footer { margin-top: 26px; padding-top: 12px; border-top: 1px solid #e6e6e6; font-size: 9px; color: #666; }
  .warn { background: #FFF8E1; border-radius: 6px; padding: 10px 14px; font-size: 10.5px; color: #7a5600; margin-bottom: 16px; }
`;

const NUCLEO = [
  'Actúas como <b>proveedor independiente</b>, no como empleado, socio ni representante de Daricefy.',
  'Cuentas con la <b>capacidad legal, permisos, licencias, seguros y experiencia</b> necesarios para prestar tu servicio conforme a la ley del lugar donde lo prestarás.',
  'Eres el único responsable de la <b>calidad, seguridad y legalidad</b> de lo que ofreces, incluyendo cualquier daño, lesión o perjuicio que tu servicio cause a clientes, invitados o terceros.',
  'Mantendrás a Daricefy libre de toda responsabilidad, y la <b>indemnizarás</b> por cualquier reclamación derivada de tu servicio.',
  'Daricefy únicamente conecta, cotiza y procesa el pago — no supervisa, inspecciona ni certifica tu trabajo.',
];

const ANEXOS: { title: string; body: string }[] = [
  {
    title: 'Comida',
    body: 'Declaras contar con los permisos sanitarios vigentes que exija tu localidad para preparar y/o servir alimentos, manejar correctamente alérgenos comunes, e informar al cliente si tu menú los contiene. Eres el único responsable ante cualquier intoxicación, alergia o incidente relacionado con los alimentos que sirvas.',
  },
  {
    title: 'Renta de mobiliario (mesas, sillas, toldos, tarimas, generadores, brincolines, inflables)',
    body: 'Declaras que tu equipo está en condiciones seguras de uso, que lo instalarás/armarás conforme a las especificaciones del fabricante, y que cuentas con seguro de responsabilidad civil si tu equipo representa riesgo físico. Eres el único responsable por daños a la propiedad del lugar o lesiones causadas por tu equipo.',
  },
  {
    title: 'Shows (payasos, mago, personajes, animación)',
    body: 'Declaras tener experiencia trabajando con el público de tu show (incluyendo menores de edad cuando aplique), usar materiales (maquillaje, pintura, accesorios) seguros e hipoalergénicos, y asumes responsabilidad por cualquier incidente físico durante tu actuación.',
  },
  {
    title: 'Luz y sonido',
    body: 'Declaras que tu instalación eléctrica cumple con normas de seguridad básicas y que cuentas con el conocimiento técnico para instalar tu equipo sin representar riesgo de descarga o incendio.',
  },
  {
    title: 'Fotógrafos / Drones / Cabina 360',
    body: 'Declaras contar con el permiso correspondiente para operar drones donde la ley lo exija, y ser responsable de obtener el consentimiento de las personas que fotografíes/grabes cuando el uso de esas imágenes lo requiera.',
  },
  {
    title: 'Música / DJ / Maestro de Ceremonias / Comediante',
    body: 'Declaras contar con los derechos o licencias necesarias para interpretar o reproducir la música/material de tu show (SACM u organismo equivalente en tu país), y ser responsable de cualquier reclamación por derechos de autor derivada de tu presentación.',
  },
];

export async function exportProviderAgreementPdf(): Promise<void> {
  const logoDataUri = await getLogoDataUri();
  const today = new Date().toLocaleDateString('es-MX', { day: '2-digit', month: 'long', year: 'numeric' });

  const html = `<!doctype html><html><head><meta charset="utf-8"><style>${BASE_CSS}</style></head><body>
${brandHeaderHtml(logoDataUri, 'Acuerdo de Proveedor de Servicios')}

<h1>Acuerdo de Proveedor de Servicios</h1>
<div class="intro">
  Este acuerdo se celebra entre <b>Daricefy</b> y la persona o negocio que se identifica al calce
  ("el Proveedor"), con motivo de ofrecer sus servicios a través de la plataforma Daricefy.
  Al firmar, el Proveedor acepta las siguientes condiciones:
</div>

<div class="warn">
  Este documento es un borrador de referencia — antes de usarlo de forma oficial, revísalo con un
  abogado en tu país. No sustituye asesoría legal profesional.
</div>

${brandCore()}

${brandAnnexes()}

<div class="sign-block">
  <h2>Datos del proveedor y firmas</h2>

  <div class="sign-row">
    <div class="sign-col">
      <div class="fill-line"></div>
      <div class="fill-label">Nombre del proveedor / negocio</div>
    </div>
    <div class="sign-col">
      <div class="fill-line"></div>
      <div class="fill-label">Categoría de servicio</div>
    </div>
  </div>

  <div class="sign-row">
    <div class="sign-col">
      <div class="sign-title">Por el Proveedor</div>
      <div class="fill-line"></div>
      <div class="fill-label">Firma</div>
    </div>
    <div class="sign-col">
      <div class="sign-title">&nbsp;</div>
      <div class="fill-line"></div>
      <div class="fill-label">Fecha</div>
    </div>
  </div>

  <div class="sign-row">
    <div class="sign-col">
      <div class="sign-title">Por Daricefy</div>
      <div class="fill-line"></div>
      <div class="fill-label">Firma</div>
    </div>
    <div class="sign-col">
      <div class="sign-title">&nbsp;</div>
      <div class="fill-line"></div>
      <div class="fill-label">Fecha</div>
    </div>
  </div>
</div>

<div class="footer">Documento generado por Daricefy el ${today}. docs/legal_provider_liability_draft.md — borrador sujeto a revisión legal.</div>
</body></html>`;

  const { uri } = await Print.printToFileAsync({ html, base64: false });
  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(uri, { mimeType: 'application/pdf', dialogTitle: 'Acuerdo de Proveedor', UTI: 'com.adobe.pdf' });
  }
}

function brandCore(): string {
  return `<h2>1. Condiciones generales</h2><ol>${NUCLEO.map(n => `<li>${n}</li>`).join('')}</ol>`;
}

function brandAnnexes(): string {
  return `<h2>2. Condiciones según tu categoría</h2>
    <p class="intro" style="margin-top:-4px;">Aplica solo el anexo de la categoría en la que el Proveedor ofrece su servicio.</p>
    ${ANEXOS.map(a => `<div class="annex"><b>${a.title}</b><p>${a.body}</p></div>`).join('')}`;
}
