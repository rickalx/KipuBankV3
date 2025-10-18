// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Ricardo Flor
 * @notice Bóveda multi-token pausable con soporte para ETH y ERC-20, umbral fijo de retiro por transacción,
 *         límite global de depósitos en USD e integración con oráculos de Chainlink para conversiones.
 * @dev Sigue el patrón checks-effects-interactions, usa errores personalizados,
 *      maneja ETH y ERC-20 de forma segura, expone eventos claros.
 *      Soporta múltiples tokens con control de acceso administrativo, contabilidad en USD y pausas de emergencia.
 */
contract KipuBankV2 is Ownable, ReentrancyGuard, Pausable {
    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Cantidad cero no permitida.
    error ZeroAmount();

    /// @notice El depósito propuesto excede el límite global del banco.
    /// @param attempted Cantidad total que se intenta alcanzar (totalVault + msg.value).
    /// @param cap Límite máximo global permitido.
    error CapExceeded(uint256 attempted, uint256 cap);

    /// @notice El monto de retiro excede el umbral fijo por transacción.
    /// @param attempted Monto solicitado a retirar.
    /// @param threshold Umbral máximo permitido por transacción.
    error ThresholdExceeded(uint256 attempted, uint256 threshold);

    /// @notice El usuario no tiene suficiente saldo en su bóveda.
    /// @param balance Saldo disponible del usuario.
    /// @param attempted Monto solicitado.
    error InsufficientVault(uint256 balance, uint256 attempted);

    /// @notice No se permiten envíos directos de ETH sin usar la función `deposit`.
    error DirectETHNotAllowed();

    /// @notice Falló la transferencia nativa (ETH) al destinatario.
    error NativeTransferFailed();

    /// @notice Parámetros inválidos en el constructor.
    error InvalidConstructorParams();

    /// @notice El token ya está soportado.
    error TokenAlreadySupported(address token);

    /// @notice El token no está soportado.
    error TokenNotSupported(address token);

    /// @notice Decimales inválidos para el token.
    error InvalidDecimals(uint8 decimals);

    /// @notice Falló la transferencia de ERC-20.
    error ERC20TransferFailed();

    /// @notice Precio inválido del oráculo.
    error InvalidOraclePrice();

    /*//////////////////////////////////////////////////////////////
                             EVENTOS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitido cuando un usuario deposita un token en su bóveda.
     * @param account Dirección del depositante.
     * @param token Dirección del token depositado.
     * @param amount Cantidad depositada.
     * @param newBalance Nuevo saldo del depositante después del depósito.
     * @param totalBalance Nuevo total global en custodia después del depósito.
     */
    event Deposited(address indexed account, address indexed token, uint256 amount, uint256 newBalance, uint256 totalBalance);

    /**
     * @notice Emitido cuando un usuario retira un token de su bóveda.
     * @param account Dirección del que retira.
     * @param token Dirección del token retirado.
     * @param amount Cantidad retirada.
     * @param newBalance Nuevo saldo del usuario después del retiro.
     * @param totalBalance Nuevo total global en custodia después del retiro.
     */
    event Withdrawn(address indexed account, address indexed token, uint256 amount, uint256 newBalance, uint256 totalBalance);

    /**
     * @notice Emitido cuando se añade un token soportado.
     * @param token Dirección del token.
     * @param decimals Decimales del token.
     */
    event TokenAdded(address indexed token, uint8 decimals);

    /**
     * @notice Emitido cuando se remueve un token soportado.
     * @param token Dirección del token removido.
     */
    event TokenRemoved(address indexed token);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Decimales de USDC (6).
     */
    uint8 public constant USDC_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                              ESTRUCTURAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Información de un token soportado.
     */
    struct TokenInfo {
        address tokenAddress;
        uint8 decimals;
    }

    /*//////////////////////////////////////////////////////////////
                          VARIABLES INMUTABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Límite global en USD (con 6 decimales) que puede custodiar el banco.
     * @dev Fijado en el despliegue; no puede cambiarse.
     */
    uint256 public immutable bankCapUsd;

    /**
     * @notice Umbral máximo (en wei) que puede retirarse por transacción.
     * @dev Fijado en el despliegue; no puede cambiarse.
     */
    uint256 public immutable withdrawThreshold;

    /**
     * @notice Instancia del feed de Chainlink para ETH/USD.
     * @dev Inicializado en el despliegue.
     */
    AggregatorV3Interface internal dataFeed;

    /*//////////////////////////////////////////////////////////////
                         VARIABLES DE ALMACENAMIENTO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Saldos totales por token custodiados por el contrato.
     * @dev Se actualiza en depósitos y retiros; se prefiere a balances reales
     *      para evitar desalineaciones ante envíos forzados.
     */
    mapping(address => uint256) public totalTokenBalances;

    /**
     * @notice Saldos totales en USD por token (con 6 decimales).
     * @dev Para monitoreo de caps en valor estable.
     */
    mapping(address => uint256) public totalTokenBalancesUsd;

    /**
     * @notice Conteo global de depósitos exitosos.
     */
    uint256 public depositCount;

    /**
     * @notice Conteo global de retiros exitosos.
     */
    uint256 public withdrawalCount;

    /**
     * @notice Saldos de bóveda por usuario y token.
     */
    mapping(address => mapping(address => uint256)) private userTokenBalances;

    /**
     * @notice Información de tokens soportados.
     */
    mapping(address => TokenInfo) public supportedTokens;

    /*//////////////////////////////////////////////////////////////
                             MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Garantiza que `amount` sea mayor que cero.
     * @param amount Cantidad a validar.
     */
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /**
     * @notice Garantiza que `amount` no exceda el umbral de retiro por transacción.
     * @param amount Cantidad a validar.
     */
    modifier underThreshold(uint256 amount) {
        if (amount > withdrawThreshold) revert ThresholdExceeded(amount, withdrawThreshold);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el contrato con el límite global en USD y umbral de retiro.
     * @param bankCapUsd_ Límite global en USD (con 6 decimales, ej. 100000000000 para $100k).
     * @param withdrawThreshold_ Umbral máximo por retiro (en wei).
     * @dev Requiere parámetros válidos: bankCapUsd_ > 0, withdrawThreshold_ > 0.
     *      Inicializa el feed ETH/USD para Sepolia.
     */
    constructor(uint256 bankCapUsd_, uint256 withdrawThreshold_) Ownable(msg.sender) {
        if (bankCapUsd_ == 0 || withdrawThreshold_ == 0) {
            revert InvalidConstructorParams();
        }
        bankCapUsd = bankCapUsd_;
        withdrawThreshold = withdrawThreshold_;

        /**
         * Network: Sepolia
         * Data Feed: ETH/USD
         * Address: 0x694AA1769357215DE4FAC081bf1f309aDC325306
         */
        dataFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);

         // Inicializar ETH como token soportado
         supportedTokens[address(0)] = TokenInfo(address(0), 18);
     }

     /*//////////////////////////////////////////////////////////////
                         FUNCIONES EXTERNAS (admin)
     //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pausa el contrato.
     * @dev Solo el owner puede pausar.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Reanuda el contrato.
     * @dev Solo el owner puede reanudar.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Añade un token soportado.
     * @param token Dirección del token ERC-20.
     * @param decimals Decimales del token.
     * @dev Solo el owner puede añadir tokens. No permite añadir ETH (address(0)) de nuevo.
     */
    function addSupportedToken(address token, uint8 decimals) external onlyOwner {
         if (token == address(0)) revert InvalidConstructorParams(); // ETH ya está soportado
         if (supportedTokens[token].tokenAddress != address(0)) revert TokenAlreadySupported(token);
         if (decimals == 0 || decimals > 18) revert InvalidDecimals(decimals); // Asumir máximo 18 decimales

         supportedTokens[token] = TokenInfo(token, decimals);
         emit TokenAdded(token, decimals);
     }

     /**
      * @notice Remueve un token soportado.
      * @param token Dirección del token a remover.
      * @dev Solo el owner puede remover. No permite remover ETH.
      */
     function removeSupportedToken(address token) external onlyOwner {
         if (token == address(0)) revert InvalidConstructorParams(); // No remover ETH
         if (supportedTokens[token].tokenAddress == address(0)) revert TokenNotSupported(token);

          delete supportedTokens[token];
          emit TokenRemoved(token);
      }



     /*//////////////////////////////////////////////////////////////
                         FUNCIONES EXTERNAS (payable)
     //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposita ETH en la bóveda del `msg.sender`.
     * @dev Sigue CEI: checks (montos y cap en USD) → effects (actualiza estado) → interactions (ninguna).
     *      Requiere envío de ETH con `msg.value`.
     * @custom:error ZeroAmount si `msg.value == 0`.
     * @custom:error CapExceeded si el total en USD excede `bankCapUsd`.
     */
    function deposit() external payable nonZero(msg.value) nonReentrant whenNotPaused {
        uint256 usdValue = convertToUsd(address(0), msg.value);
        uint256 newTotalUsd = totalTokenBalancesUsd[address(0)] + usdValue;
        if (newTotalUsd > bankCapUsd) {
            revert CapExceeded(newTotalUsd, bankCapUsd);
        }

        // Effects
        userTokenBalances[msg.sender][address(0)] += msg.value;
        totalTokenBalances[address(0)] += msg.value;
        totalTokenBalancesUsd[address(0)] = newTotalUsd;
        unchecked {
            depositCount += 1;
        }

         emit Deposited(msg.sender, address(0), msg.value, userTokenBalances[msg.sender][address(0)], totalTokenBalances[address(0)]);
     }

    /**
     * @notice Deposita un ERC-20 token en la bóveda del `msg.sender`.
     * @param token Dirección del token ERC-20 a depositar.
     * @param amount Cantidad a depositar.
     * @dev Usa transferFrom para transferir tokens desde `msg.sender`. Requiere aprobación previa.
     * @custom:error ZeroAmount si `amount == 0`.
     * @custom:error TokenNotSupported si el token no está soportado.
     */
    function depositERC20(address token, uint256 amount) external nonZero(amount) nonReentrant whenNotPaused {
        if (supportedTokens[token].tokenAddress == address(0)) revert TokenNotSupported(token);

         uint256 usdValue = convertToUsd(token, amount);
         uint256 newTotalUsd = totalTokenBalancesUsd[token] + usdValue;
         if (newTotalUsd > bankCapUsd) {
             revert CapExceeded(newTotalUsd, bankCapUsd);
         }

         // Interactions
         if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert ERC20TransferFailed();

         // Effects
         userTokenBalances[msg.sender][token] += amount;
         totalTokenBalances[token] += amount;
         totalTokenBalancesUsd[token] = newTotalUsd;
         unchecked {
             depositCount += 1;
         }

         emit Deposited(msg.sender, token, amount, userTokenBalances[msg.sender][token], totalTokenBalances[token]);
     }

    /**
     * @notice Retira `amount` de ETH de la bóveda del `msg.sender`.
     * @param amount Monto a retirar (en wei).
     * @dev Sigue CEI: checks → effects → interactions.
     * @custom:error ZeroAmount si `amount == 0`.
     * @custom:error ThresholdExceeded si `amount > withdrawThreshold`.
     * @custom:error InsufficientVault si el saldo del usuario es insuficiente.
     * @custom:error NativeTransferFailed si falla el envío de ETH.
     */
    function withdraw(uint256 amount)
        external
        nonZero(amount)
        underThreshold(amount)
        nonReentrant
        whenNotPaused
    {
        uint256 balance = userTokenBalances[msg.sender][address(0)];
        if (balance < amount) revert InsufficientVault(balance, amount);

        // Effects
        uint256 usdValue = convertToUsd(address(0), amount);
        unchecked {
            userTokenBalances[msg.sender][address(0)] = balance - amount;
            totalTokenBalances[address(0)] -= amount;
            totalTokenBalancesUsd[address(0)] -= usdValue;
            withdrawalCount += 1;
        }

        // Interactions
        _sendETH(msg.sender, amount);

        emit Withdrawn(msg.sender, address(0), amount, userTokenBalances[msg.sender][address(0)], totalTokenBalances[address(0)]);
    }

    /**
     * @notice Retira `amount` de un ERC-20 token de la bóveda del `msg.sender`.
     * @param token Dirección del token ERC-20 a retirar.
     * @param amount Monto a retirar.
     * @dev Sigue CEI: checks → effects → interactions.
     * @custom:error ZeroAmount si `amount == 0`.
     * @custom:error TokenNotSupported si el token no está soportado.
     * @custom:error ThresholdExceeded si `amount > withdrawThreshold`.
     * @custom:error InsufficientVault si el saldo del usuario es insuficiente.
     */
    function withdrawERC20(address token, uint256 amount)
        external
        nonZero(amount)
        underThreshold(amount)
        nonReentrant
        whenNotPaused
    {
        if (supportedTokens[token].tokenAddress == address(0)) revert TokenNotSupported(token);

        uint256 balance = userTokenBalances[msg.sender][token];
        if (balance < amount) revert InsufficientVault(balance, amount);

        // Effects
         uint256 usdValue = convertToUsd(token, amount);
         unchecked {
             userTokenBalances[msg.sender][token] = balance - amount;
             totalTokenBalances[token] -= amount;
             totalTokenBalancesUsd[token] -= usdValue;
             withdrawalCount += 1;
         }

        // Interactions
        if (!IERC20(token).transfer(msg.sender, amount)) revert ERC20TransferFailed();

        emit Withdrawn(msg.sender, token, amount, userTokenBalances[msg.sender][token], totalTokenBalances[token]);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES EXTERNAS (view)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Devuelve el saldo de bóveda para una cuenta y token.
     * @param account Dirección a consultar.
     * @param token Dirección del token.
     * @return balance Saldo del token.
     */
    function vaultOf(address account, address token) external view returns (uint256 balance) {
        return userTokenBalances[account][token];
    }

    /**
     * @notice Retorna una vista compacta de la configuración inmutable.
     * @return capUsd Límite global del banco en USD (6 decimales).
     * @return threshold Umbral fijo por retiro (wei).
     * @return feed Dirección del feed ETH/USD.
     */
    function getConfig() external view returns (uint256 capUsd, uint256 threshold, address feed) {
        return (bankCapUsd, withdrawThreshold, address(dataFeed));
    }

    /**
     * @notice Obtiene el precio actual de ETH en USD desde Chainlink.
     * @return price Precio de ETH en USD (con 8 decimales).
     * @dev Usa el feed de Chainlink; revierte si precio <= 0.
     */
    function getEthUsdPrice() public view returns (uint256 price) {
        (, int256 answer,,,) = dataFeed.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice();
        return uint256(answer);
    }

    /**
     * @notice Convierte una cantidad de token a USD con 6 decimales.
     * @param token Dirección del token.
     * @param amount Cantidad a convertir.
     * @return usdValue Valor en USD con 6 decimales.
     * @dev Solo soporta ETH por ahora.
     */
    function convertToUsd(address token, uint256 amount) public view returns (uint256 usdValue) {
        if (token == address(0)) {
            // ETH: amount in wei (18 dec), price in 8 dec, USD in 6 dec
            uint256 ethPrice = getEthUsdPrice();
            usdValue = (amount * ethPrice) / (10 ** (18 + 8 - 6));
        } else {
            // Para otros tokens, asumir precio fijo o revertir
            revert TokenNotSupported(token);
        }
    }



    /*//////////////////////////////////////////////////////////////
                         FUNCIONES PRIVADAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Envía ETH de forma segura usando `call`.
     * @param to Destinatario.
     * @param amount Monto en wei.
     * @dev No se reenvía gas fijo como `transfer`/`send`; se usa `call` y se valida el resultado.
     *      Mantiene CEI: solo se llama tras actualizar el estado.
     */
    function _sendETH(address to, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }


    /*//////////////////////////////////////////////////////////////
                         RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Evita depósitos accidentales vía `receive`. Fuerza el uso de `deposit()`.
     */
    receive() external payable {
        revert DirectETHNotAllowed();
    }

    /**
     * @dev Evita llamadas a funciones inexistentes con valor.
     */
    fallback() external payable {
        if (msg.value > 0) revert DirectETHNotAllowed();
        // De lo contrario, ignora silenciosamente llamadas sin valor.
    }
}
