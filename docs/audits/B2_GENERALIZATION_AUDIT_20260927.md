# ATLAS B2 — Auditoría de Generalización FingerFood → Motor

Fecha: 2026-09-27
Rama: audit/b2-generalization-20260927
Base: backup/b2-2-closed-20260906
Estado: AUDITORÍA ACTIVA / SIN DESPLIEGUE

## Objetivo
Determinar qué aprendizajes obtenidos durante la construcción y pruebas de Valentina para FingerFood pertenecen al núcleo reusable de ATLAS/B2, cuáles son configuración específica de empresa y cuáles deben convertirse en criterios de instalación/certificación para cualquier empresa futura.

## Hallazgo principal confirmado
B2 ya dispone de una capa robusta de instalación, gates, normalización, provisioning, integraciones, testing, aprobación final, certificado y activación.

La capa B2.2I histórica está canónicamente fijada a exactamente 18 pruebas activas. El materializador valida 17 REQUIRED + 1 CONDITIONAL = 18 y G03 vuelve a exigir un total de 18 casos. El cierre de continuidad B2.2L.5 también verifica 18 definiciones de prueba activas.

Por tanto, agregar nuevas pruebas top-level rompiendo ese cardinal histórico NO es un cambio seguro. La ruta correcta es versionar la certificación o enriquecer los contratos de assertions manteniendo intacto el cierre histórico.

## Cobertura empresarial que YA existe en B2
El inventario B2 ya contempla explícitamente:
- identidad y actividad de empresa;
- PRODUCTS_SERVICES como catálogo/fuente canónica;
- COMMERCIAL_POLICIES;
- PAYMENT_METHODS_TERMS;
- FAQ_SERVICE_LIMITS;
- AGENT_PERSONALITY_PROFILE;
- INVENTORY_AVAILABILITY cuando aplica;
- QUOTES_AND_TEMPLATES cuando aplica;
- MEDIA_TECHNICAL_DOCUMENTS cuando los productos requieren imágenes/fichas;
- WhatsApp/Meta y otros conectores como requisitos condicionales;
- normalización, promoción a datos canónicos y provisioning por empresa.

Conclusión: la separación conceptual COMPANY_CONFIG ya está bien encaminada en B2. El principal gap no es “dónde guardar catálogo o imágenes”, sino “cómo certificar con suficiente profundidad que el agente sabe conversar y operar correctamente usando esa configuración”.

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
- catálogo y precios;
- tacos y sus variantes/referencia visual;
- porcentaje de anticipo y políticas comerciales propias;
- plantillas PDF y tarjeta de pago;
- datos bancarios, WhatsApp, correo, Instagram y textos legales;
- reglas particulares de eventos, productos, cantidades y restricciones.

B2 debe ingerir/normalizar estos datos; CORE no debe conocer nombres de productos FingerFood.

## Gap de certificación detectado
Las 18 pruebas B2 actuales son necesarias, pero varias son demasiado gruesas para certificar por sí solas la calidad conversacional requerida antes de producción.

Especialmente:
- KNOWLEDGE_SEARCH_ACCURACY debe certificar grounding y rechazo de hechos no sustentados;
- COMMERCIAL_RULES_ENFORCEMENT debe certificar ambigüedad, intent gating, aceptación explícita y modificación;
- EXTERNAL_CONVERSATION_E2E debe certificar continuidad, acknowledgements sin retrigger, autocorrección y no-loop;
- DOCUMENT_TEMPLATE_OUTPUT debe certificar que el documento corresponde al estado/versión canónica actual;
- MEDIA/visual debe quedar como configuración empresarial y luego tener una prueba funcional reusable cuando el capability esté activo.

## Cambio creado en esta rama
Se agregó una extensión aditiva y versionada:
- `atlas_test_assertion_contract_v2`
- smoke test asociado.

La V2 NO cambia el número histórico de 18 pruebas ni modifica G03. En cambio, agrega assertions reutilizables dentro de pruebas existentes:
- CANONICAL_SOURCE_GROUNDING
- UNSUPPORTED_FACT_REJECTION
- UNSUPPORTED_ATTRIBUTE_INFERENCE_BLOCKED
- AMBIGUITY_REQUIRES_CLARIFICATION
- ACTION_INTENT_GATING
- EXPLICIT_ACCEPTANCE_GATING
- MODIFICATION_OVERRIDES_STALE_ACCEPTANCE
- CONVERSATION_CONTEXT_CONTINUITY
- ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER
- SELF_CORRECTION_FINAL_INTENT_WINS
- CONTEXTUAL_MODIFICATION_NO_LOOP
- DOCUMENT_BOUND_TO_CURRENT_CANONICAL_STATE

El smoke test incluye una defensa explícita para impedir que términos específicos de FingerFood se filtren al CORE reusable.

## Dependencias downstream confirmadas
Hardcodes/assumptions de 18 pruebas encontrados en:
1. B2.2I.2A materialización del plan: exige exactamente 18 definiciones y 17+1.
2. B2.2I.3 readiness G03: exige `v_total_case_count = 18`.
3. B2.2L.5 continuidad: exige 18 definiciones activas.

B2.2I.2B ya trabaja con `required_case_count + conditional_case_count` y es más flexible, por lo que no aparece como blocker principal para una futura V2.

## Regla de diseño
B2 no debe certificar solamente que “los datos están cargados”. Debe certificar que la Valentina instalada sabe conversar y operar con esos datos bajo lenguaje natural, ambigüedad, correcciones y continuaciones reales.

## Arquitectura objetivo
1. CORE runtime reusable.
2. COMPANY_CONFIG canónica por tenant/empresa.
3. B2 installer que transforma inputs de empresa en configuración canónica.
4. B2 certification que genera y ejecuta pruebas técnicas + conversacionales.
5. UAT humana final de la empresa antes de producción.

## Próximo paso técnico
No modificar los contratos históricos certificados V1.

Construir una ruta B2 test-plan V2 que:
- siga usando 18 top-level capabilities si queremos compatibilidad;
- materialice expected_assertions mediante `atlas_test_assertion_contract_v2`;
- versiona el contrato de plan, hashes y readiness;
- preserve coexistencia V1/V2;
- solo sustituya V1 para nuevas instalaciones después de smoke tests + certificación.

Estado: preparado para diseño/implementación V2 en rama aislada.