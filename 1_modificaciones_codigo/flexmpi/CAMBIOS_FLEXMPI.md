# Cambios en ficheros fuente (distintos de lanza_xpn.sh)

## 1. epidemiology_sync.c
**Fichero:** `install-src/EpiGraphFlexMPI-XPN/src/epidemiology/epidemiology_sync.c`
**Línea ~403**
**Motivo:** EMPI_Monitor_init() se llamaba cada MINDAY (1440 iter), pero EMPI_Monitor_end() se llama cada iteración. PAPI no se reseteaba al mismo ritmo que se leía → métricas corruptas.

```c
// ANTES:
if ((liTimeStamp % MINDAY) == 0) {
    EMPI_Monitor_init();
}

// DESPUÉS:
if ((liTimeStamp % EMPI_GLOBAL_niter_lb) == 0) {
    EMPI_Monitor_init();
}
```

---

## 2. monitor.c — evento PAPI
**Fichero:** `install-src/FlexMPIDeveloper/src/monitor.c`
**Línea ~438**
**Motivo:** El evento `PAPI_TOT_INS` fue introducido por error en una sesión anterior en lugar de `PAPI_FP_OPS`. `PAPI_TOT_INS` devuelve `PAPI_ENOEVNT` en Docker Swarm → FLOPs = 0. Revertido a `PAPI_FP_OPS` el 2026-04-24.

```c
// ANTES (incorrecto):
if((retval = PAPI_add_event (EMPI_GLOBAL_PAPI_eventSet, PAPI_TOT_INS)) != PAPI_OK ){

// DESPUÉS (correcto):
if((retval = PAPI_add_event (EMPI_GLOBAL_PAPI_eventSet, PAPI_FP_OPS)) != PAPI_OK ){
```

---

## 2b. monitor.c — MALLEABILITY_TRIG lbalance
**Fichero:** `install-src/FlexMPIDeveloper/src/monitor.c`
**Línea ~4207**
**Motivo:** En la política MALLEABILITY_TRIG, cuando el controlador no enviaba comandos add/remove, EMPI_LBalance estaba comentado y nunca se llamaba.

```c
// ANTES:
else{
    // David
    //int lbalance = EMPI_NULL;
    //if (EMPI_GLOBAL_lbalance == EMPI_TRUE) lbalance = EMPI_LBalance (rank, size, count, disp, fc, smonitor);
    // David
}

// DESPUÉS:
else{
    // David
    int lbalance = EMPI_NULL;
    if (EMPI_GLOBAL_lbalance == EMPI_TRUE) lbalance = EMPI_LBalance (rank, size, count, disp, fc, smonitor);
    // David
}
```

---

## 3. lbalance.c
**Fichero:** `install-src/FlexMPIDeveloper/src/lbalance.c`
**Línea ~1201**
**Motivo:** El rebalanceo por CPU (TCPU) solo se activaba si el sistema era DEDICATED. Los procesos ligeros, bloqueados en barreras MPI (ptime << rtime), se marcaban como NON_DEDICATED → el sistema nunca rebalanceaba por CPU.

---

## 5. lbalance.c (tercera modificación)
**Fichero:** `install-src/FlexMPIDeveloper/src/lbalance.c`
**Línea ~1185**
**Motivo:** FlexMPI salía antes del check de CPU si TREAL aparecía balanceado. En MPI síncrono todos los procesos tienen RTIME similar (esperan al más lento en barreras), así que TREAL siempre parece balanceado aunque CPU no lo esté.

```c
// ANTES:
if (real_balance == EMPI_BALANCED) {

// DESPUÉS:
if (real_balance == EMPI_BALANCED && cpu_balance == EMPI_BALANCED) {
```

---

## 4. lbalance.c (segunda modificación)
**Fichero:** `install-src/FlexMPIDeveloper/src/lbalance.c`
**Línea ~1177**
**Motivo:** Si cualquier rank tiene FLOPs = 0 (PAPI no mide correctamente en Docker/CPU híbrida), EMPI_LBalance salía antes de evaluar el imbalance de CPU.

```c
// ANTES:
for (n = 0; n < *size; n ++) if (smonitor[n].flops == 0) return EMPI_ERROR;

// DESPUÉS (comentado):
//for (n = 0; n < *size; n ++) if (smonitor[n].flops == 0) return EMPI_ERROR;
```

---

## 6. monitor.c — spawn con FLOPs = 0 asigna 0 filas a procesos originales
**Fichero:** `install-src/FlexMPIDeveloper/src/monitor.c`
**Línea ~4690**
**Motivo:** En `EMPI_Monitor_spawn`, `stflops[n]` para los procesos existentes se calcula como `flops/rtime`. Si FLOPs = 0 (PAPI no disponible en Docker), `stflops[0..size-1] = 0` pero `stflops[size..size+nprocs-1] = class->mflops = 5000`. La distribución de carga tras el spawn asigna `count * (0/20000) = 0` filas a los originales y todas a los nuevos → PTIME ≈ 0 en los originales → bloqueo en barreras MPI → RTIME se dispara.

```c
// DESPUÉS (fallback a distribución equitativa cuando FLOPs = 0):
int any_old_zero = 0;
for (n = 0; n < *size; n++) if (stflops[n] == 0) { any_old_zero = 1; break; }
if (any_old_zero) {
    for (n = 0; n < (*size + nprocs); n++) stflops[n] = 1;
}
```

---

## 3. lbalance.c (primera modificación)
**Fichero:** `install-src/FlexMPIDeveloper/src/lbalance.c`
**Línea ~1201**
**Motivo:** El rebalanceo por CPU (TCPU) solo se activaba si el sistema era DEDICATED. Los procesos ligeros, bloqueados en barreras MPI (ptime << rtime), se marcaban como NON_DEDICATED → el sistema nunca rebalanceaba por CPU.

```c
// ANTES:
if (((EMPI_GLOBAL_hmon[EMPI_GLOBAL_hpos] == EMPI_DEDICATED) && (cpu_balance == EMPI_UNBALANCED))
|| ((external_load == EMPI_BURST) && (cpu_balance == EMPI_UNBALANCED))) {

// DESPUÉS:
if (cpu_balance == EMPI_UNBALANCED) {
```
