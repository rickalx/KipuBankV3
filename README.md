# KipuBankV3

Un contrato de bóveda multi-token en Ethereum con integración de Uniswap V4 para depósitos de tokens arbitrarios, intercambiando automáticamente a USDC. Soporta aprobaciones sin gas vía Permit2.

## Características

- **Soporte Multi-token**: Deposita ETH, USDC o cualquier token ERC-20.
- **Integración Uniswap V4**: Intercambio automático de tokens arbitrarios a USDC usando UniversalRouter.
- **Soporte Permit2**: Aprobaciones de tokens sin gas para depósitos fluidos.
- **Seguridad**: Guards de reentrancia, pausable, validación de entrada, límites de cap del banco.
- **Integración de Oráculos**: Feeds de precios ETH/USD de Chainlink para seguimiento de valor en USD.
- **Controles de Admin**: El propietario puede añadir tokens soportados, establecer tarifas de pool, pausar/reanudar.

## Arquitectura

- **KipuBankV3.sol**: Contrato principal con lógica de depósito/retiro e integración Uniswap.
- **Interfaces**: Interfaces personalizadas para componentes Uniswap V4 y Permit2.
- **Tests**: Tests unitarios e de integración con dependencias mockeadas.

## Instalación

```shell
git clone <repo>
cd KipuBankV3
forge install
```

## Uso

### Construir

```shell
forge build
```

### Testear

```shell
forge test
```

### Desplegar

Actualiza `script/Deploy.s.sol` con parámetros del constructor, luego:

```shell
forge script script/Deploy.s.sol --rpc-url <rpc_url> --private-key <private_key> --broadcast
```

### Interactuar

Usa `script/Interactions.s.sol` para interacciones post-despliegue.

## API

### Funciones de Depósito

- `deposit()`: Deposita ETH.
- `depositERC20(address token, uint256 amount)`: Deposita ERC-20 soportado.
- `depositArbitraryToken(address _tokenIn, uint256 _amountIn, uint256 _minUsdcOut, bytes _permit)`: Deposita cualquier token, auto-intercambia a USDC. Usa `_permit` para aprobaciones Permit2.

### Funciones de Retiro

- `withdraw(uint256 amount)`: Retira ETH.
- `withdrawERC20(address token, uint256 amount)`: Retira ERC-20.

### Funciones de Admin

- `addSupportedToken(address token, uint8 decimals)`
- `setPoolFee(address _tokenIn, uint24 _fee)`
- `pause()` / `unpause()`

### Funciones de Vista

- `vaultOf(address account, address token)`: Saldo del usuario.
- `BANK_CAP_USD()`: Cap global en USD.
- `WITHDRAW_THRESHOLD()`: Máximo retiro por tx.

## Seguridad

- Sigue el patrón CEI.
- Protegido contra reentrancia.
- Entrada validada.
- Llamadas externas a contratos confiables (Uniswap, Permit2, Chainlink).
- Cap del banco enforced antes de swaps/transfers.

## Testing

Ejecuta tests con mocks para cobertura unitaria. Tests de integración requieren fork de Sepolia (actualiza clave Infura).

Cobertura: >95% objetivo.

## Contrato Desplegado y verificado

[KipuBankV2](https://sepolia.etherscan.io/address/0x3a4e26ed7840f6dd743a1ebdb426c97859102015#code)

## Decisiones de Diseño y Trade-offs

- **Integración con Uniswap V4**: Proporciona funcionalidad avanzada para swaps arbitrarios, pero aumenta la complejidad del contrato y dependencias externas. Trade-off: Flexibilidad vs. simplicidad y riesgo de fallos en protocolos externos.
- **Uso de Permit2**: Permite aprobaciones sin gas, mejorando la UX, pero introduce complejidad adicional en la validación de permisos y dependencias. Trade-off: Experiencia de usuario vs. seguridad y mantenibilidad.
- **Límite de Cap del Banco (bankCap)**: Enforced antes de operaciones para prevenir overflows, pero limita la escalabilidad y requiere cálculos precisos de valor. Trade-off: Seguridad vs. flexibilidad de uso.
- **Oráculos Chainlink**: Proporciona precios precisos para conversiones USD, pero añade costo de llamadas externas y dependencia de oráculos. Trade-off: Precisión vs. costo y confiabilidad.
- **Patrón CEI (Checks-Effects-Interactions)**: Mejora la seguridad contra reentrancia, pero complica el orden de operaciones en funciones complejas como swaps. Trade-off: Seguridad vs. legibilidad y eficiencia.
- **Soporte Multi-token con Auto-swap**: Permite depósitos arbitrarios, pero requiere lógica adicional para manejar diferentes tipos de tokens y swaps. Trade-off: Conveniencia vs. complejidad y potenciales errores en rutas de swap.
- **Pausable y Admin Controls**: Permite respuestas rápidas a emergencias, pero concentra poder en el propietario. Trade-off: Seguridad operativa vs. descentralización.
- **Uso de Inmutables en SCREAMING_SNAKE_CASE**: Mejora la legibilidad y sigue convenciones, pero requiere cambios en el código. Trade-off: Estándares vs. compatibilidad.

## Licencia

MIT
