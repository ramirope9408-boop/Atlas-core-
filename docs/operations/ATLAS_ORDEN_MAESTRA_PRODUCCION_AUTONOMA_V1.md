# ATLAS — ORDEN MAESTRA DE PRODUCCIÓN AUTÓNOMA V1

Fecha: 2026-09-27
Ámbito: ATLAS / B2 / Valentina / módulos futuros
Modo: CONSTRUIR → VALIDAR → CORREGIR → RETESTEAR → CERTIFICAR → PROSEGUIR
Estado: ACTIVA COMO REGLA OPERATIVA DE CONSTRUCCIÓN

## 1. Propósito

Evitar el patrón de trabajo fragmentado en el que cada cambio menor requiere una nueva autorización humana.

Mientras exista una autorización global de construcción vigente, el sistema de trabajo de ATLAS debe avanzar por bloques completos, acumulando construcción, validación, corrección y certificación antes de volver al propietario con un reporte.

La unidad de trabajo deja de ser “un cambio” y pasa a ser “un bloque certificado”.

## 2. Regla principal

Ante una fase autorizada:

1. inspeccionar el estado real;
2. construir lo faltante;
3. detectar dependencias;
4. identificar posibles modos de fallo;
5. crear validaciones para esos modos de fallo;
6. ejecutar pruebas;
7. corregir automáticamente todo lo corregible;
8. volver a ejecutar las pruebas;
9. ejecutar regresión;
10. clasificar lo no resoluble;
11. certificar únicamente lo probado;
12. continuar con el siguiente bloque compatible;
13. entregar al propietario un reporte consolidado.

No detenerse por cada error intermedio si puede resolverse de forma segura dentro del alcance autorizado.

## 3. Autoridad operativa permanente dentro de una fase

Se consideran autorizadas sin nueva consulta:

- crear ramas de trabajo aisladas;
- crear y modificar código;
- crear migraciones;
- crear pruebas;
- crear documentación técnica;
- refactorizar código no desplegado;
- corregir errores detectados por pruebas;
- añadir guards, assertions, validadores y observabilidad;
- crear datos sintéticos de prueba;
- ejecutar pruebas locales o en entornos aislados;
- repetir pruebas tras correcciones;
- realizar regresión;
- consultar GitHub, Supabase y otras fuentes técnicas conectadas;
- inspeccionar esquemas, RPCs, Edge Functions, logs y contratos;
- crear paquetes de certificación;
- marcar PASS / FAIL / PARTIAL / BLOCKED / NOT_TESTED según evidencia;
- continuar al siguiente bloque cuando los gates anteriores estén satisfechos.

## 4. Casos en los que NO se interrumpe al propietario

No pedir autorización adicional por:

- errores de sintaxis;
- errores de compilación;
- constraints incorrectos;
- permisos internos mal conectados;
- imports rotos;
- funciones faltantes;
- casos edge no cubiertos;
- tests fallidos;
- regresiones detectadas;
- fallos de idempotencia;
- inconsistencias entre contrato y runtime;
- nombres de función/constraint incorrectos;
- fallos de tipado;
- problemas de orden de migraciones;
- errores de datos sintéticos;
- ajustes de prompt de pruebas;
- endurecimiento de seguridad en código aún no desplegado;
- creación de nuevas pruebas para un error descubierto.

La respuesta esperada ante esos casos es:
DETECTAR → CORREGIR → RETESTEAR → REGRESIÓN → PROSEGUIR.

## 5. Casos que SÍ requieren intervención humana

Solo detener el avance cuando ocurra uno de estos límites:

### A. Dinero nuevo
- iniciar un plan pago;
- aceptar un cargo;
- crear infraestructura que genere costo recurrente;
- adquirir dominios, servicios o créditos.

### B. Producción irreversible o de impacto externo
- borrar datos de producción;
- degradar o reemplazar un sistema productivo sin rollback;
- cambiar Meta/WhatsApp de producción;
- activar un workflow productivo nuevo;
- migrar tráfico real;
- revocar credenciales productivas;
- merge/cutover cuando la operación pudiera afectar clientes reales y no exista rollback certificado.

### C. Secretos / identidad / autorización externa
- introducir credenciales no disponibles;
- completar 2FA;
- aceptar términos legales externos;
- autorizar cuentas bancarias o financieras.

### D. Decisión empresarial no inferible
- política comercial que el negocio nunca definió;
- precio;
- porcentaje de anticipo;
- términos legales;
- alcance comercial;
- decisión que cambie materialmente el producto contratado.

Si el problema no pertenece a A–D, se resuelve técnicamente y se continúa.

## 6. Motor de errores

Cada bloque debe mantener un catálogo de errores posibles, no solo errores ya observados.

Clasificación:

- BUILD_ERROR
- SQL_ERROR
- MIGRATION_ORDER_ERROR
- CONTRACT_MISMATCH
- TYPE_ERROR
- PERMISSION_ERROR
- AUTHORITY_GAP
- TENANT_ISOLATION_ERROR
- STATE_MACHINE_ERROR
- IDEMPOTENCY_ERROR
- DATA_BINDING_ERROR
- GROUNDING_ERROR
- AMBIGUITY_ERROR
- ACTION_GATING_ERROR
- ACCEPTANCE_GATING_ERROR
- MODIFICATION_LOOP
- CONTEXT_CONTINUITY_ERROR
- VISUAL_GROUNDING_ERROR
- DOCUMENT_VERSION_ERROR
- PROVIDER_ERROR
- CHANNEL_ERROR
- OBSERVABILITY_GAP
- REGRESSION
- PERFORMANCE_ERROR
- SECURITY_ERROR
- EVIDENCE_GAP
- EXTERNAL_BLOCKER

Por cada error:
1. registrar evidencia;
2. localizar capa;
3. corregir la causa, no solo el síntoma;
4. añadir prueba de regresión;
5. retest;
6. cerrar solo con evidencia.

## 7. Regla de promoción

Nada pasa a “certificado” porque compile o porque una prueba aislada funcione.

Para promover un bloque:

BUILD_OK
→ STATIC_VALIDATION_OK
→ UNIT/CONTRACT_TESTS_OK
→ INTEGRATION_TESTS_OK
→ STATEFUL_TESTS_OK
→ REGRESSION_OK
→ SECURITY/PERMISSION_CHECK_OK
→ EVIDENCE_COMPLETE
→ CERTIFIED

Cuando un bloque dependa de infraestructura no disponible:
BLOCKED_EXTERNAL, con el resto del trabajo técnico continuando cuando sea posible.

## 8. Regla B2 / empresa

Todos los hallazgos durante una implementación empresarial deben clasificarse como:

- CORE
- COMPANY_CONFIG
- B2_INSTALLER
- INTEGRATION_ADAPTER

Si es reusable, debe regresar al motor.
Si es específico de empresa, debe vivir en configuración.
No hardcodear una empresa en CORE.

## 9. Regla de regresión obligatoria

Cada error corregido genera una nueva prueba.

Una corrección no está cerrada hasta comprobar:

- caso original resuelto;
- capacidades previas no rotas;
- tenant isolation intacto;
- permisos intactos;
- contratos históricos compatibles;
- rollback o coexistencia cuando aplica.

## 10. Reporte al propietario

No reportar cada microacción.

Reportar al completar un bloque significativo o al encontrar un límite A–D.

Formato mínimo:

- BLOQUE TRABAJADO
- QUÉ SE CONSTRUYÓ
- QUÉ FALLÓ
- QUÉ SE CORRIGIÓ
- QUÉ PRUEBAS PASARON
- QUÉ SIGUE BLOQUEADO
- ESTADO DE CERTIFICACIÓN
- SIGUIENTE BLOQUE

## 11. Filosofía operativa

ATLAS no se construye como una secuencia de preguntas humanas.

Se construye como un sistema de ingeniería con gates:

CONSTRUIR
→ ROMPER EN PRUEBAS
→ ENTENDER POR QUÉ
→ CORREGIR
→ VOLVER A ROMPER
→ REGRESIÓN
→ CERTIFICAR
→ PROSEGUIR

El propietario interviene en decisiones empresariales, dinero nuevo y producción de alto impacto.
La máquina de construcción se encarga del resto.

## 12. Regla de velocidad

Priorizar avance contundente sobre avance fragmentado.

Una sesión debe intentar cerrar un bloque completo, no acumular aprobaciones de microcambios.

El objetivo operativo es reducir ciclos de consulta humana y aumentar ciclos automáticos de validación/corrección.

## 13. Estado actual de aplicación

Esta orden aplica inmediatamente al trabajo en:
- audit/b2-generalization-20260927
- B2 Test Plan V2
- certificación conversacional
- runner multi-turn
- regresión
- validación SQL/TypeScript
- paquetes de certificación/UAT

No autoriza por sí sola un gasto nuevo ni un cutover irreversible de producción.



## 14. Regla de aceleración de 30 días

Ventana operativa: primeros 30 días de infraestructura de desarrollo acelerada.

Objetivo: producir avances reales, grandes y medibles en ATLAS. Esta ventana no se usa para acumular documentación, microajustes o aprobaciones parciales sin cierre.

### 14.1 Unidad mínima de progreso

La unidad mínima de progreso es un BLOQUE FUNCIONAL CERRADO.

Un bloque solo cuenta como avance real cuando cumple, según aplique:

- código creado o corregido;
- migraciones listas;
- pruebas ejecutables;
- errores detectados y corregidos;
- regresión pasada;
- evidencia registrada;
- estado de certificación definido;
- integración con el bloque siguiente preparada.

Documentación sin implementación no cuenta como avance principal.

### 14.2 Prioridad de ejecución

Durante estos 30 días se prioriza, en este orden:

1. B2 V2 y fábrica de instalación/certificación.
2. Valentina reusable y preparada para producción.
3. Runtime conversacional universal.
4. Certificación multiempresa.
5. Integración técnica necesaria para despliegue seguro.
6. UI/operación solo cuando desbloquee el uso real.
7. Ramas futuras de ATLAS únicamente si no interrumpen los objetivos anteriores.

### 14.3 Regla de profundidad

No saltar de módulo en módulo dejando capas incompletas.

Cuando se abre un bloque:
- construir;
- validar;
- romper en pruebas;
- corregir;
- retestear;
- hacer regresión;
- certificar;
- entonces continuar.

### 14.4 Regla de velocidad

Se evita reportar microprogreso.

El sistema debe intentar cerrar múltiples subfases dentro de una misma sesión antes de volver al propietario, salvo límites A-D definidos en esta orden.

### 14.5 Métricas de avance

Cada bloque debe poder responder:

- qué capacidad nueva existe;
- qué error real fue eliminado;
- qué prueba nueva quedó permanente;
- qué porcentaje del flujo está certificado;
- qué riesgo técnico disminuyó;
- qué dependencia dejó de bloquear;
- qué parte del camino a producción se acortó.

### 14.6 Prohibición de falsa velocidad

No se considera avance:
- crear archivos sin conectarlos;
- escribir planes sin ejecución;
- declarar PASS sin prueba;
- acumular TODOs;
- duplicar arquitectura;
- rehacer lo ya certificado sin motivo;
- mover problemas a otra capa;
- crear features nuevas mientras el bloque crítico sigue roto.

### 14.7 Resultado esperado al día 30

Al cierre de la ventana se debe tener evidencia suficiente para decidir si la infraestructura acelerada se mantiene o se reduce.

La evaluación se hará por resultados, no por percepción.

Preguntas de cierre:
- ¿cuántos bloques funcionales quedaron certificados?
- ¿qué parte de Valentina está realmente lista para producción?
- ¿B2 puede instalar y certificar otra empresa sin trabajo artesanal?
- ¿cuánto disminuyó la intervención humana por microdecisiones?
- ¿cuántos errores se detectaron automáticamente antes de producción?
- ¿cuánto tiempo promedio tarda ahora un ciclo construir→corregir→certificar?

Si los resultados justifican el costo, se mantiene la infraestructura.
Si no, se vuelve a un modo de menor costo sin perder lo construido.

### 14.8 Regla ejecutiva

Durante esta ventana, el objetivo no es “trabajar mucho”.

El objetivo es que ATLAS termine cada semana materialmente más cerca de operar, instalar clientes y generar ingresos.
