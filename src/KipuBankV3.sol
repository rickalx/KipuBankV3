// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {
    AggregatorV3Interface
} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// New V4 imports
import "./interfaces/IUniversalRouter.sol";
import "./interfaces/IV4Router.sol";
import "./interfaces/IPoolManager.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IPermit2.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title KipuBankV3
 * @author Ricardo Flor
 * @notice Bóveda multi-token pausable con soporte para ETH y ERC-20, umbral fijo de retiro por transacción,
 *         límite global de depósitos en USD e integración con oráculos de Chainlink para conversiones.
 *         Upgrade to V3: Integrates Uniswap V4 UniversalRouter for arbitrary token deposits, auto-swapping to USDC.
 * @dev Sigue el patrón checks-effects-interactions, usa errores personalizados,
 *      maneja ETH y ERC-20 de forma segura, expone eventos claros.
 *      Soporta múltiples tokens con control de acceso administrativo, contabilidad en USD y pausas de emergencia.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard, Pausable {
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

    // New V3 errors
    /// @notice Invalid pool fee.
    error InvalidPoolFee();

    /// @notice Slippage exceeded.
    error SlippageExceeded();

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
    event Deposited(
        address indexed account, address indexed token, uint256 amount, uint256 newBalance, uint256 totalBalance
    );

    /**
     * @notice Emitido cuando un usuario retira un token de su bóveda.
     * @param account Dirección del que retira.
     * @param token Dirección del token retirado.
     * @param amount Cantidad retirada.
     * @param newBalance Nuevo saldo del usuario después del retiro.
     * @param totalBalance Nuevo total global en custodia después del retiro.
     */
    event Withdrawn(
        address indexed account, address indexed token, uint256 amount, uint256 newBalance, uint256 totalBalance
    );

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

    // New V3 events
    /**
     * @notice Emitido cuando se actualiza la tarifa de pool para un token.
     * @param token Dirección del token.
     * @param fee Nueva tarifa de pool.
     */
    event PoolFeeUpdated(address indexed token, uint24 fee);

    /**
     * @notice Emitido cuando se realiza un swap de tokens.
     * @param account Dirección del usuario.
     * @param tokenIn Token de entrada.
     * @param tokenOut Token de salida.
     * @param amountIn Cantidad de entrada.
     * @param amountOut Cantidad de salida.
     */
    event TokenSwapped(address indexed account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTES
     //////////////////////////////////////////////////////////////*/

    /**
     * @notice Decimales de USDC (6).
     */
    uint8 public constant USDC_DECIMALS = 6;

    // New V3 constants
    uint24 public constant DEFAULT_POOL_FEE = 3000; // 0.3%
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%

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
    uint256 public immutable BANK_CAP_USD;

    /**
     * @notice Umbral máximo (en wei) que puede retirarse por transacción.
     * @dev Fijado en el despliegue; no puede cambiarse.
     */
    uint256 public immutable WITHDRAW_THRESHOLD;

    /**
     * @notice Instancia del feed de Chainlink para ETH/USD.
     * @dev Inicializado en el despliegue.
     */
    AggregatorV3Interface internal dataFeed;

    // New V3 immutables
    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    IWETH public immutable WETH;
    address public immutable USDC;
    IPoolManager public immutable POOL_MANAGER;
    IPermit2 public immutable PERMIT2;

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

    // New V3 storage
    mapping(address => uint24) public poolFees;

    /*//////////////////////////////////////////////////////////////
                              MODIFICADORES
     //////////////////////////////////////////////////////////////*/

    /**
     * @notice Garantiza que `amount` sea mayor que cero.
     * @param amount Cantidad a validar.
     */
    modifier nonZero(uint256 amount) {
        _nonZero(amount);
        _;
    }

    /**
     * @notice Garantiza que `amount` no exceda el umbral de retiro por transacción.
     * @param amount Cantidad a validar.
     */
    modifier underThreshold(uint256 amount) {
        _underThreshold(amount);
        _;
    }

    function _nonZero(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    function _underThreshold(uint256 amount) internal view {
        if (amount > WITHDRAW_THRESHOLD) revert ThresholdExceeded(amount, WITHDRAW_THRESHOLD);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
     //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el contrato con el límite global en USD y umbral de retiro.
     * @param bankCapUsd_ Límite global en USD (con 6 decimales, ej. 100000000000 para $100k).
     * @param withdrawThreshold_ Umbral máximo por retiro (en wei).
     * @param universalRouter_ Dirección del UniversalRouter de Uniswap V4.
     * @param weth_ Dirección del contrato WETH.
     * @param usdc_ Dirección del contrato USDC.
     * @param poolManager_ Dirección del PoolManager de Uniswap V4.
     * @param permit2_ Dirección del contrato Permit2.
     * @param dataFeed_ Dirección del feed ETH/USD.
     * @dev Requiere parámetros válidos: bankCapUsd_ > 0, withdrawThreshold_ > 0.
     *      Inicializa el feed ETH/USD.
     */
    constructor(
        uint256 bankCapUsd_,
        uint256 withdrawThreshold_,
        address universalRouter_,
        address weth_,
        address usdc_,
        address poolManager_,
        address permit2_,
        address dataFeed_
    ) Ownable(msg.sender) {
        if (
            bankCapUsd_ == 0 || withdrawThreshold_ == 0 || universalRouter_ == address(0) || weth_ == address(0)
                || usdc_ == address(0) || poolManager_ == address(0) || permit2_ == address(0)
                || dataFeed_ == address(0)
        ) {
            revert InvalidConstructorParams();
        }
        BANK_CAP_USD = bankCapUsd_;
        WITHDRAW_THRESHOLD = withdrawThreshold_;
        UNIVERSAL_ROUTER = IUniversalRouter(universalRouter_);
        WETH = IWETH(weth_);
        USDC = usdc_;
        POOL_MANAGER = IPoolManager(poolManager_);
        PERMIT2 = IPermit2(permit2_);
        dataFeed = AggregatorV3Interface(dataFeed_);

        // Inicializar ETH como token soportado
        supportedTokens[address(0)] = TokenInfo({tokenAddress: address(0), decimals: 18});
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

        supportedTokens[token] = TokenInfo({tokenAddress: token, decimals: decimals});
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

    // New V3 admin function
    function setPoolFee(address _tokenIn, uint24 _fee) external onlyOwner {
        poolFees[_tokenIn] = _fee;
        emit PoolFeeUpdated(_tokenIn, _fee);
    }

    function getPoolFee(address _tokenIn) public view returns (uint24) {
        uint24 fee = poolFees[_tokenIn];
        return fee == 0 ? DEFAULT_POOL_FEE : fee;
    }

    function _calculateMinAmount(uint256 _expectedAmount, uint256 _slippageBps) internal pure returns (uint256) {
        return _expectedAmount * (10000 - _slippageBps) / 10000;
    }

    function _sortCurrencies(address tokenIn, address tokenOut) internal pure returns (Currency, Currency) {
        Currency c0 = Currency.wrap(tokenIn);
        Currency c1 = Currency.wrap(tokenOut);
        if (Currency.unwrap(c0) < Currency.unwrap(c1)) {
            return (c0, c1);
        } else {
            return (c1, c0);
        }
    }

    function _swapExactInputSingle(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        private
        returns (uint256 amountOut)
    {
        address tokenIn = _tokenIn;
        if (tokenIn == address(0)) {
            tokenIn = address(WETH);
            WETH.deposit{value: _amountIn}();
        }

        (Currency c0, Currency c1) = _sortCurrencies(tokenIn, _tokenOut);
        bool zeroForOne = Currency.unwrap(c0) == tokenIn;

        uint24 fee = getPoolFee(_tokenIn);

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 60, hooks: IHooks(address(0))});

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        Actions[] memory actions = new Actions[](3);
        actions[0] = Actions.SWAP_EXACT_IN_SINGLE;
        actions[1] = Actions.SETTLE_ALL;
        actions[2] = Actions.TAKE_ALL;

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey, zeroForOne, _amountIn, _minAmountOut);
        params[1] = abi.encode(Currency.wrap(tokenIn));
        params[2] = abi.encode(Currency.wrap(_tokenOut), address(this));

        inputs[0] = abi.encode(actions, params);

        if (tokenIn != address(0)) {
            IERC20(tokenIn).approve(address(UNIVERSAL_ROUTER), _amountIn);
        }

        uint256 balanceBefore = IERC20(_tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp);
        uint256 balanceAfter = IERC20(_tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;

        if (amountOut < _minAmountOut) revert SlippageExceeded();
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
        if (newTotalUsd > BANK_CAP_USD) {
            revert CapExceeded(newTotalUsd, BANK_CAP_USD);
        }

        // Effects
        userTokenBalances[msg.sender][address(0)] += msg.value;
        totalTokenBalances[address(0)] += msg.value;
        totalTokenBalancesUsd[address(0)] = newTotalUsd;
        unchecked {
            depositCount += 1;
        }

        emit Deposited(
            msg.sender, address(0), msg.value, userTokenBalances[msg.sender][address(0)], totalTokenBalances[address(0)]
        );
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
        if (newTotalUsd > BANK_CAP_USD) {
            revert CapExceeded(newTotalUsd, BANK_CAP_USD);
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
     * @notice Deposita cualquier token soportado (ETH, USDC, o ERC-20), lo swap a USDC via Uniswap V4, y acredita el USDC a la bóveda del usuario.
     * @param _tokenIn Dirección del token de entrada (address(0) para ETH).
     * @param _amountIn Cantidad de entrada.
     * @param _minUsdcOut Mínimo USDC a recibir (0 para usar slippage default).
     * @param _permit Datos de permit para Permit2 (PermitSingle + signature, vacío si usa allowance).
     * @dev Enforces bankCap before swap. Handles ETH wrapping, USDC direct deposit, and ERC-20 swaps with Permit2.
     */
    function depositArbitraryToken(address _tokenIn, uint256 _amountIn, uint256 _minUsdcOut, bytes calldata _permit)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (_amountIn == 0) revert ZeroAmount();
        if (_tokenIn == address(0) && msg.value != _amountIn) revert InvalidConstructorParams(); // For ETH, msg.value must match

        // Handle Permit2 if provided
        if (_permit.length > 0) {
            (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
                abi.decode(_permit, (IPermit2.PermitSingle, bytes));
            // Validate permit matches the deposit
            if (permitSingle.details.token != _tokenIn || permitSingle.details.amount < _amountIn ||
                permitSingle.spender != address(this) || permitSingle.sigDeadline < block.timestamp) {
                revert InvalidConstructorParams();
            }
            PERMIT2.permit(msg.sender, permitSingle, signature);
        }

        // Ensure amount fits in uint160 for Permit2
        if (_amountIn > type(uint160).max) revert InvalidConstructorParams();

        uint256 minUsdcOut;
        if (_minUsdcOut == 0) {
            if (_tokenIn == address(0)) {
                // For ETH, calculate based on price
                uint256 usdValue = convertToUsd(address(0), _amountIn);
                minUsdcOut = _calculateMinAmount(usdValue, DEFAULT_SLIPPAGE_BPS);
            } else {
                // Rough estimate for others
                minUsdcOut = _calculateMinAmount(_amountIn, DEFAULT_SLIPPAGE_BPS);
            }
        } else {
            minUsdcOut = _minUsdcOut;
        }

        // Pre-check bankCap with minimum expected output
        uint256 expectedAmountOut = _tokenIn == USDC ? _amountIn : minUsdcOut;
        uint256 newTotalUsdMin = totalTokenBalancesUsd[USDC] + expectedAmountOut;
        if (newTotalUsdMin > BANK_CAP_USD) {
            revert CapExceeded(newTotalUsdMin, BANK_CAP_USD);
        }

        uint256 amountOut;
        if (_tokenIn == USDC) {
            // Direct USDC deposit
            if (_permit.length > 0) {
                // casting to 'uint160' is safe because _amountIn is checked <= type(uint160).max
                PERMIT2.transferFrom(msg.sender, address(this), uint160(_amountIn), USDC);
            } else {
                if (!IERC20(USDC).transferFrom(msg.sender, address(this), _amountIn)) revert ERC20TransferFailed();
            }
            amountOut = _amountIn;
        } else if (_tokenIn == address(0)) {
            // ETH: already received via msg.value
            amountOut = _swapExactInputSingle(_tokenIn, USDC, _amountIn, minUsdcOut);
        } else {
            // ERC-20: transfer to contract
            if (_permit.length > 0) {
                // casting to 'uint160' is safe because _amountIn is checked <= type(uint160).max
                PERMIT2.transferFrom(msg.sender, address(this), uint160(_amountIn), _tokenIn);
            } else {
                if (!IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn)) revert ERC20TransferFailed();
            }
            // Swap to USDC
            amountOut = _swapExactInputSingle(_tokenIn, USDC, _amountIn, minUsdcOut);
        }

        // Final check with actual amountOut (should pass since amountOut >= minUsdcOut)
        uint256 newTotalUsd = totalTokenBalancesUsd[USDC] + amountOut;
        if (newTotalUsd > BANK_CAP_USD) {
            revert CapExceeded(newTotalUsd, BANK_CAP_USD);
        }

        // Effects
        userTokenBalances[msg.sender][USDC] += amountOut;
        totalTokenBalances[USDC] += amountOut;
        totalTokenBalancesUsd[USDC] = newTotalUsd;
        unchecked {
            depositCount += 1;
        }

        // Events
        if (_tokenIn != USDC) {
            emit TokenSwapped(msg.sender, _tokenIn, USDC, _amountIn, amountOut);
        }
        emit Deposited(msg.sender, USDC, amountOut, userTokenBalances[msg.sender][USDC], totalTokenBalances[USDC]);
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
    function withdraw(uint256 amount) external nonZero(amount) underThreshold(amount) nonReentrant whenNotPaused {
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

        emit Withdrawn(
            msg.sender, address(0), amount, userTokenBalances[msg.sender][address(0)], totalTokenBalances[address(0)]
        );
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
        return (BANK_CAP_USD, WITHDRAW_THRESHOLD, address(dataFeed));
    }

    /**
     * @notice Obtiene el precio actual de ETH en USD desde Chainlink.
     * @return price Precio de ETH en USD (con 8 decimales).
     * @dev Usa el feed de Chainlink; revierte si precio <= 0.
     */
    function getEthUsdPrice() public view returns (uint256 price) {
        (, int256 answer,,,) = dataFeed.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice();
        // casting to 'uint256' is safe because answer > 0
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
        (bool ok,) = to.call{value: amount}("");
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
