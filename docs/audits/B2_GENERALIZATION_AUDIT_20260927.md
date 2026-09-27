# ATLAS B2 — Auditoría de Generalización FingerFood → Motor

Fecha: 2026-09-27
Rama: audit/b2-generalization-20260927
Base: backup/b2-2-closed-20260906
Estado: AUDITORÍA ACTIVA / SIN DESPLIEGUE

## Objetivo
Determinar qué aprendizajes obtenidos durante la construcción y pruebas de Valentina para FingerFood pertenecen al núcleo reusable de ATLAS/B2, cuáles son configuración específica de empresa y cuáles deben convertirse en criterios de instalación/certificación para cualquier empresa futura.

## Hallazgo principal confirmado
B2 ya dispone de una capa robusta de instalación, gates, normalización, provisioning, integraciones, testing, aprobación final, certificado y activación. Sin embargo, la capa de testing B2.2I está canónicamente fijada a exactamente 18 pruebas activas y el materializador de planes valida explícitamente 17 REQUIRED + 1 CONDITIONAL = 18.

Esto cubre identidad, aislamiento, roles, archivos, knowledge search, reglas comerciales, conversación E2E, control humano, herramientas, auditoría, idempotencia, errores, recovery, integraciones, documentos, voz y rendimiento.

No existen todavía como contratos de prueba first-class separados varios comportamientos conversacionales descubiertos durante FingerFood.

## Clasificación obligatoria desde este corte
Todo cambio nuevo de Valentina debe quedar clasificado como una de estas categorías:
- CORE: comportamiento reusable independiente de la empresa.
- COMPANY_CONFIG: datos, catálogo, políticas, imágenes, plantillas, tono y reglas propias de una empresa.
- B2_INSTALLER: extracción, normalización, instalación, generación de pruebas y certificación de una empresa.
- INTEGRATION_ADAPTER: comportamiento específico de un canal o proveedor externo.

No se admite lógica de negocio FingerFood hardcodeada dentro de CORE.

## Aprendizajes FingerFood que deben ser CORE
1. Context continuity: una respuesta corta como “dale”, “listo”, “ok” o “quedo atento” no debe repetir ni inventar una acción previa.
2. Explicit action gating: pagos, modificaciones, envíos o efectos materiales requieren el estado/intención correcta y no deben dispararse por mera afinidad semántica.
3. Acceptance distinction: interés, confirmación conversacional y aceptación comercial son estados distintos.
4. Modification context: una autocorrección o modificación debe aplicarse al objeto activo correcto y después cerrar el intent de modificación para evitar loops.
5. Grounding / anti-invention: si una respuesta no está sustentada por knowledge/configuración canónica, Valentina pregunta o escala; no inventa.
6. Ambiguity handling: ante datos insuficientes o referencias ambiguas, pregunta antes de ejecutar.
7. Visual grounding: una imagen enviada debe corresponder a la entidad o familia solicitada; las referencias específicas de cada empresa viven en COMPANY_CONFIG.
8. Regression safety: una corrección nueva no puede romper capacidades ya certificadas.

## Aprendizajes que son COMPANY_CONFIG
Ejemplos FingerFood:
- Catálogo y precios.
- Tacos y sus tres variantes/referencia visual.
- Porcentaje de anticipo y políticas comerciales propias.
- Plantillas PDF y tarjeta de pago.
- Datos bancarios, WhatsApp, correo, Instagram y textos legales del negocio.
- Reglas particulares de eventos, productos, cantidades y restricciones.

B2 debe ingerir/normalizar estos datos; CORE no debe conocer nombres de productos FingerFood.

## Gap de certificación detectado
Las 18 pruebas B2 actuales son necesarias pero demasiado gruesas para certificar por sí solas la calidad conversacional que se espera antes de salida a producción.

Debe existir una extensión de certificación conversacional reusable, al menos con estos casos first-class:
- CONVERSATION_CONTEXT_CONTINUITY
- AMBIGUITY_CLARIFICATION
- GROUNDING_NO_FABRICATION
- ACTION_INTENT_GATING
- EXPLICIT_ACCEPTANCE_GATING
- CONTEXTUAL_MODIFICATION_NO_LOOP
- VISUAL_REFERENCE_GROUNDING (condicional cuando existen activos visuales)
- CONVERSATION_REGRESSION_SUITE

## Regla de diseño
B2 no debe certificar solamente que “los datos están cargados”. Debe certificar que la Valentina instalada sabe conversar y operar con esos datos bajo lenguaje natural, ambigüedad, correcciones y continuaciones reales.

## Arquitectura objetivo
1. CORE runtime reusable.
2. COMPANY_CONFIG canónica por tenant/empresa.
3. B2 installer que transforma inputs de empresa en configuración canónica.
4. B2 certification que genera y ejecuta pruebas técnicas + conversacionales.
5. UAT humana final de la empresa antes de producción.

## Estado del cambio
- Rama de trabajo aislada creada.
- No hay cambios aplicados a producción.
- No se ha alterado el cierre certificado B2.2.
- Siguiente trabajo: revisar dependencias downstream que asumen exactamente 18 pruebas y diseñar una extensión versionada del contrato de test plan, evitando modificar retrospectivamente contratos históricos certificados.
