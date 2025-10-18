# 🏦 KipuBank V2

KipuBank V2 es un contrato inteligente avanzado escrito en Solidity que implementa una **bóveda multi-token pausable** con soporte para ETH y ERC-20, reglas de seguridad estrictas, límites en USD, y integración con oráculos de Chainlink:

## Contrato Desplegado y verificado

[KipuBankV2](https://sepolia.etherscan.io/address/0x82b0c432c889FA27CDBFc0590dCe79DF04bFF108#code)

- Los usuarios pueden **depositar ETH o ERC-20 tokens** en su bóveda personal.
- Pueden **retirar tokens**, pero únicamente hasta un **umbral fijo por transacción** (`withdrawThreshold`).
- El contrato impone un **límite global de depósitos en USD** (`bankCapUsd`) monitoreado vía oráculos.
- Soporta **múltiples tokens** con control administrativo para añadir/remover.
- Incluye **pausas de emergencia** para seguridad.
- Se lleva un registro de:
  - Saldos por usuario y token (`vaultOf(address, address)`).
  - Totales globales por token (`totalTokenBalances`).
  - Totales en USD (`totalTokenBalancesUsd`).
  - Conteo global de depósitos/retiros (`depositCount`, `withdrawalCount`).
- Los depósitos y retiros emiten **eventos detallados** (`Deposited`, `Withdrawn`).
- Se aplican **errores personalizados** para revertir condiciones inválidas.

Este contrato sigue buenas prácticas modernas de seguridad:
- Uso de **CEI (Checks → Effects → Interactions)**.
- Transferencias seguras con verificación de éxito.
- `receive` y `fallback` bloqueados para evitar envíos accidentales.
- Variables inmutables y constantes bien documentadas.
- Protección contra reentrancy y pausas de emergencia.

---

## 🚀 Despliegue con Remix IDE

### Pasos

1. Abre [Remix IDE](https://remix.ethereum.org/).
2. Crea un nuevo archivo en la carpeta `contracts/` llamado `KipuBankV2.sol`.
3. Copia y pega el código del contrato.
4. Compila el contrato usando el compilador de Solidity `^0.8.30`.
5. Ve a la pestaña **Deploy & Run Transactions**.
6. Selecciona el contrato `KipuBankV2` en el desplegable.
7. Ingresa los parámetros del constructor:
   - `bankCapUsd`: límite global en USD con 6 decimales (ej. `100000000000` para $100k).
   - `withdrawThreshold`: umbral máximo de retiro en wei (ej. `1000000000000000000` para `1 ether`).
   (El feed ETH/USD está hardcodeado para Sepolia).
8. Haz clic en **Deploy**.
9. El contrato estará desplegado y listo para usarse en la red seleccionada (JavaScript VM, Injected Provider, o una red real como Sepolia/Mainnet).

---

## 💻 Interacción

### 1. Depositar ETH
En Remix o Foundry, llama `deposit()` enviando ETH en el campo **Value**.  
Ejemplo:  
- Seleccionar `deposit`  
- Poner `2` en el campo Value (ETH)  
- Ejecutar  

### 2. Depositar ERC-20
Llama `depositERC20(address token, uint256 amount)` después de aprobar el token.  
Ejemplo:  
- `token`: dirección del ERC-20  
- `amount`: cantidad en unidades del token  

### 3. Retirar ETH
Llama `withdraw(uint256 amount)` con el monto en wei.  
Ejemplo:  
- `amount = 500000000000000000` (`0.5 ether`)  

### 4. Retirar ERC-20
Llama `withdrawERC20(address token, uint256 amount)`.  

### 5. Administrar Tokens
- Añadir: `addSupportedToken(address token, uint8 decimals)` (solo owner).
- Remover: `removeSupportedToken(address token)` (solo owner).

### 6. Pausar/Reanudar
- Pausar: `pause()` (solo owner).
- Reanudar: `unpause()` (solo owner).

### 7. Consultas
- Saldo: `vaultOf(address account, address token)`.
- Config: `getConfig()` devuelve `bankCapUsd`, `withdrawThreshold`, `ethUsdFeed`.
- Precio ETH: `getEthUsdPrice()`.
- Conversión: `convertToUsd(address token, uint256 amount)`.
- Totales: `totalTokenBalances(address token)`, `totalTokenBalancesUsd(address token)`.

---

## 🔧 Mejoras implementadas

El contrato incluye mejoras avanzadas para seguridad, escalabilidad y usabilidad.

### 1. Soporte Multi-Token
- **Descripción**: Soporta ETH y ERC-20 tokens con administración de tokens soportados.
- **Beneficio**: Flexibilidad para múltiples activos.

### 2. Contabilidad en USD
- **Descripción**: Límites globales en USD usando oráculos de Chainlink para estabilidad.
- **Beneficio**: Caps resistentes a volatilidad de precios.

### 3. Integración con Oráculos
- **Descripción**: Usa Chainlink para precios ETH/USD en tiempo real.
- **Beneficio**: Conversiones precisas y monitoreo de valor.

### 4. Pausable para Emergencias
- **Descripción**: El owner puede pausar depósitos/retiros en caso de vulnerabilidades.
- **Beneficio**: Mitigación rápida de riesgos.

### 5. Protección contra Reentrancy
- **Descripción**: Usa ReentrancyGuard en todas las funciones críticas.
- **Beneficio**: Prevención de ataques de reentrancy.

### 6. Errores Personalizados y Eventos
- **Descripción**: Errores como `ZeroAmount()`, `CapExceeded(...)`; eventos detallados.
- **Beneficio**: Mejor debugging y eficiencia en gas/UI parsing.

### 7. Contadores y Métricas
- **Descripción**: `depositCount`, `withdrawalCount` para estadísticas rápidas.
- **Beneficio**: Métricas sin leer toda la blockchain.

### 8. Inmutables y Constantes
- **Descripción**: Configuración fija tras despliegue.
- **Beneficio**: Predictibilidad y seguridad.

### 9. Transferencias Seguras
- **Descripción**: ETH con `call`, ERC-20 con verificación de retorno.
- **Beneficio**: Compatibilidad y seguridad.

### 10. Bloqueo de Envíos Directos
- **Descripción**: `receive`/`fallback` bloqueados.
- **Beneficio**: Consistencia en contabilidad.

---

## 📋 Decisiones de Diseño y Trade-offs

- **USD Caps**: Usar USD para estabilidad, pero requiere oráculos; trade-off: dependencia externa y costos de gas.
- **Pausable**: Permite paradas de emergencia, pero el owner tiene poder centralizado; trade-off: seguridad vs. confianza.
- **Multi-Token**: Soporte ERC-20, pero solo ETH tiene conversión USD; trade-off: flexibilidad vs. complejidad.
- **Threshold Uniforme**: Aplica a todos los tokens en wei, no ajustado por decimales; trade-off: simplicidad vs. precisión.
- **No Upgrades**: Contrato no upgradeable para simplicidad; trade-off: inmutabilidad vs. corrección de bugs.

---

## 📖 Referencias
- [NatSpec en Solidity](https://docs.soliditylang.org/en/latest/natspec-format.html)
- [Checks-Effects-Interactions](https://solidity-by-example.org/hacks/re-entrancy/)
- [Solidity docs: receive / fallback](https://docs.soliditylang.org/en/latest/contracts.html#receive-ether-function)
- [Chainlink Data Feeds](https://docs.chain.link/data-feeds)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)

---
