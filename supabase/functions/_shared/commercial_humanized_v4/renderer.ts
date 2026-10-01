import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import { Image } from 'imagescript';
import { amount, businessDate, type Json } from './contract.ts';

export type Field={key:string,x:number,y:number,w:number,h:number,size:number,color?:string,background?:string,bold?:boolean};
export type Layout={width:number,height:number,fields:Field[],table?:{x:number,y:number,width:number,rowHeight:number,rowsPerPage:number,columns:{key:string,x:number,width:number}[]}};
export function values(payload:Json):Json {
  const q=payload.quote||{},p=payload.payment?.payment||{},currency=q.currency||'COP';
  const tz=payload.timezone||'America/Bogota';
  const stamp=(s:string)=>s?new Intl.DateTimeFormat('es-CO',{timeZone:tz,day:'2-digit',month:'2-digit',year:'numeric'}).format(new Date(s)):'';
  const policy=payload.policy||{}; const desc=(policy.commercial_rules||[]).map((r:Json)=>r.metadata?.description).filter(Boolean);
  return {...payload.company,display_id:`${q.document_display_id||''} - V${q.quote_version||1}`,
    issued_date:stamp(q.document_issued_at),valid_until:stamp(q.document_valid_until_at),status:'COTIZACIÓN',
    client_name:q.client_name||'',client_phone:q.client_phone||'',client_email:q.client_email||'',client_address:payload.client_address||'',
    event_type:q.metadata?.event_type||'',event_date:q.event_date?businessDate(q.event_date):'',event_location:q.event_location||'',people_count:String(q.people_count||''),event_time:q.metadata?.event_time||'',
    subtotal:amount(Number(q.subtotal_productos||0)+Number(q.subtotal_servicios||0),currency),discount:amount(q.descuento_total||0,currency),
    transport:payload.transport_amount==null?'Por confirmar':amount(payload.transport_amount,currency),
    total:amount(q.total||0,currency),deposit:amount(q.deposit_amount||0,currency),balance:amount(q.balance_amount||0,currency),
    deposit_label:`ANTICIPO (${q.deposit_percent||0}%)`,reference:q.document_display_id||'',
    payment_total:amount(p.quote_total||0,currency),payment_deposit:amount(p.amount||0,currency),payment_balance:amount(p.balance_after_payment||0,currency),
    conditions:`Vigencia: ${q.metadata?.validity_hours||96} horas.\n`+desc.filter((s:string)=>!/mínimo|minimo|descuento/i.test(s)).slice(0,4).join('\n')};
}
function color(s='#FAF7F3'){return rgb(parseInt(s.slice(1,3),16)/255,parseInt(s.slice(3,5),16)/255,parseInt(s.slice(5,7),16)/255);}
function clean(s:unknown){return String(s??'').replace(/[\u202f\u00a0]/g,' ').replace(/[–—]/g,'-');}
export async function renderQuote(asset:Uint8Array,layout:Layout,payload:Json,fontData?:Uint8Array):Promise<Uint8Array> {
  if(!layout.table||layout.table.rowsPerPage<1)throw new Error('QUOTE_LAYOUT_REQUIRED');
  const q=payload.quote;const allRows=[...(payload.products||[]),...(payload.services||[])];
  const net=allRows.reduce((n:number,r:Json)=>n+Number(r.line_total),0);
  if(!Number.isFinite(net)||Math.abs(net-Number(q.total))>0.005)throw new Error('DOCUMENT_LINE_TOTAL_MISMATCH');
  if(Math.abs(Number(q.total)-Number(q.deposit_amount)-Number(q.balance_amount))>0.005)throw new Error('DOCUMENT_PAYMENT_MISMATCH');
  const pdf=await PDFDocument.create();
  const issued=new Date(q.document_issued_at);if(!Number.isFinite(issued.getTime()))throw new Error('DOCUMENT_ISSUE_DATE_REQUIRED');
  pdf.setCreationDate(issued);pdf.setModificationDate(issued);pdf.setProducer('ATLAS canonical asset renderer');pdf.setCreator('ATLAS');
  const bg=await pdf.embedPng(asset);
  pdf.registerFontkit(fontkit);
  const regular=await pdf.embedFont(fontData||StandardFonts.Helvetica,{subset:true}),bold=fontData?regular:await pdf.embedFont(StandardFonts.HelveticaBold);
  const rows=[...(payload.products||[]).map((p:Json)=>({category:'ALIMENTOS',description:p.nombre,quantity:p.cantidad,unit:p.unidad_medida||'unidad',unit_price:amount(p.precio_unitario_final??p.precio_unitario,payload.quote.currency),line_total:amount(p.line_total,payload.quote.currency)})),...(payload.services||[]).map((p:Json)=>({category:p.service_type,description:p.descripcion,quantity:p.cantidad,unit:'servicio',unit_price:amount(p.precio_unitario,payload.quote.currency),line_total:amount(p.line_total,payload.quote.currency)}))];
  if(!rows.length)throw new Error('EMPTY_QUOTE_FORBIDDEN');
  const v=values(payload),count=Math.ceil(rows.length/layout.table.rowsPerPage);
  for(let pn=0;pn<count;pn++){
    const page=pdf.addPage([layout.width,layout.height]);page.drawImage(bg,{x:0,y:0,width:layout.width,height:layout.height});
    const field=(f:Field,text:unknown)=>{
      if(f.background)page.drawRectangle({x:f.x,y:layout.height-f.y-f.h,width:f.w,height:f.h,color:color(f.background)});
      const font=f.bold?bold:regular;const lines=clean(text).split('\n');let size=f.size;
      while(size>7&&lines.some(t=>font.widthOfTextAtSize(t,size)>f.w-6))size-=0.25;
      if(lines.some(t=>font.widthOfTextAtSize(t,size)>f.w-6)||lines.length*size*1.2>f.h)throw new Error(`TEMPLATE_FIELD_OVERFLOW:${f.key}`);
      lines.forEach((t,i)=>page.drawText(t,{x:f.x+3,y:layout.height-f.y-size-3-i*size*1.2,size,font,color:color(f.color||'#161616')}));
    };
    for(const f of layout.fields)field(f,v[f.key]);
    const t=layout.table;
    for(let n=0;n<t.rowsPerPage;n++){
      const row=rows[pn*t.rowsPerPage+n];
      for(const c of t.columns)field({key:c.key,x:c.x,y:t.y+n*t.rowHeight,w:c.width,h:t.rowHeight-1,size:13,background:n%2?'#FAF7F3':'#FCFAF7'},row?(c.key==='index'?pn*t.rowsPerPage+n+1:(row as Json)[c.key]):'');
    }
    page.drawText(`${pn+1} / ${count}`,{x:layout.width-70,y:12,size:10,font:regular,color:rgb(1,1,1)});
  }
  return await pdf.save();
}
export async function renderPayment(asset:Uint8Array,layout:Layout,payload:Json,font:Uint8Array):Promise<Uint8Array>{
  const q=payload.quote,p=payload.payment;
  if(!p?.ready||q.id!==p.quote_builder_id||Number(q.total)!==Number(p.payment.quote_total)||Number(q.deposit_amount)!==Number(p.payment.amount)||Number(q.balance_amount)!==Number(p.payment.balance_after_payment))throw new Error('PAYMENT_TRUTH_MISMATCH');
  const img=await Image.decode(asset);if(img.width!==layout.width||img.height!==layout.height)throw new Error('TEMPLATE_DIMENSIONS_MISMATCH');
  const v=values(payload);
  for(const f of layout.fields){
    if(f.background){const c=Number.parseInt(f.background.slice(1)+'ff',16);img.composite(new Image(f.w,f.h).fill(c),f.x,f.y);}
    let size=f.size;let text=await Image.renderText(font,size,clean(v[f.key]),0x171717ff);
    while((text.width>f.w||text.height>f.h)&&size>8){size--;text=await Image.renderText(font,size,clean(v[f.key]),0x171717ff);}
    if(text.width>f.w||text.height>f.h)throw new Error('TEMPLATE_FIELD_OVERFLOW:'+f.key);
    img.composite(text,f.x,f.y);
  }
  return await img.encode();
}