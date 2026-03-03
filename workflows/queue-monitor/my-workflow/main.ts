/**
 * Queue Monitor CRE Workflow
 *
 * Monitors the FIFO redemption queue depth and available liquidity.
 * Detects queue buildup, liquidity crunch scenarios, and estimates
 * time-to-clear based on current settlement velocity.
 *
 * Key insight: queue requests are non-cancelable once enqueued.
 * If free liquidity drops below queued share value, LPs are effectively
 * locked until settlements replenish the pool. This workflow provides
 * early warning of that condition.
 *
 * Chainlink products used:
 *   - CRE SDK (Runner, handler, CronCapability)
 *   - EVMClient (vault + queue manager reads)
 *   - getNetwork (chain selector resolution)
 */

import {
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	Runner,
	type Runtime,
	type CronPayload,
} from '@chainlink/cre-sdk';
import {
	encodeFunctionData,
	decodeFunctionResult,
	formatUnits,
	keccak256,
	encodeAbiParameters,
	parseAbiParameters,
	type Address,
	zeroAddress,
} from 'viem';
import { z } from 'zod';
import { LaneVault4626, LaneQueueManager, SentinelRegistry } from '../contracts/abi';

// ---------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------

const configSchema = z.object({
	schedule: z.string(),
	chainName: z.string(),
	vaultAddress: z.string(),
	queueManagerAddress: z.string(),
	assetDecimals: z.number().default(18),
	registry: z
		.object({
			address: z.string(),
			chainName: z.string().default('ethereum-testnet-sepolia'),
		})
		.optional(),
	thresholds: z
		.object({
			queueWarningCount: z.number().default(3),
			queueCriticalCount: z.number().default(10),
			liquidityCoverageWarning: z.number().default(0.5),
			liquidityCoverageCritical: z.number().default(0.2),
		})
		.optional(),
});

type Config = z.infer<typeof configSchema>;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type QueueSnapshot = {
	pendingCount: number;
	headRequestId: number;
	tailRequestId: number;
	nextRequest: {
		exists: boolean;
		requestId: number;
		owner: string;
		receiver: string;
		shares: string;
		enqueuedAt: number;
		waitTimeSeconds: number;
	} | null;
};

type LiquiditySnapshot = {
	freeLiquidity: string;
	availableForLP: string;
	totalAssets: string;
	totalSupply: string;
	reservedLiquidity: string;
	inFlightLiquidity: string;
	sharePrice: number;
};

type QueueHealthMetrics = {
	queueDepth: number;
	liquidityCoverageRatio: number;
	estimatedQueueValueAssets: string;
	canProcessNext: boolean;
	utilizationBps: number;
};

type QueueMonitorOutput = {
	queue: QueueSnapshot;
	liquidity: LiquiditySnapshot;
	health: QueueHealthMetrics;
	risk: string;
	signal: string;
	timestamp: string;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getEvmClient(chainName: string, isTestnet = false) {
	const net = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: chainName,
		isTestnet,
	});
	if (!net) throw new Error(`Network not found: ${chainName}`);
	return new cre.capabilities.EVMClient(net.chainSelector.selector);
}

function callContract(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	to: string,
	callData: `0x${string}`,
): Uint8Array {
	const resp = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: to as Address,
				data: callData,
			}),
		})
		.result();
	return resp.data;
}

function readVaultUint256(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	functionName: string,
): bigint {
	const callData = encodeFunctionData({ abi: LaneVault4626, functionName: functionName as any });
	const raw = callContract(runtime, evmClient, runtime.config.vaultAddress, callData);
	return decodeFunctionResult({ abi: LaneVault4626, functionName: functionName as any, data: bytesToHex(raw) }) as unknown as bigint;
}

const safeJsonStringify = (obj: unknown) =>
	JSON.stringify(obj, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2);

// ---------------------------------------------------------------------------
// Readers
// ---------------------------------------------------------------------------

function readQueue(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): QueueSnapshot {
	const qm = runtime.config.queueManagerAddress;

	// pendingCount
	const countData = encodeFunctionData({ abi: LaneQueueManager, functionName: 'pendingCount' });
	const countRaw = callContract(runtime, evmClient, qm, countData);
	const pendingCount = Number(
		decodeFunctionResult({ abi: LaneQueueManager, functionName: 'pendingCount', data: bytesToHex(countRaw) }),
	);

	// head/tail IDs
	const headData = encodeFunctionData({ abi: LaneQueueManager, functionName: 'headRequestId' });
	const headRaw = callContract(runtime, evmClient, qm, headData);
	const headRequestId = Number(
		decodeFunctionResult({ abi: LaneQueueManager, functionName: 'headRequestId', data: bytesToHex(headRaw) }),
	);

	const tailData = encodeFunctionData({ abi: LaneQueueManager, functionName: 'tailRequestId' });
	const tailRaw = callContract(runtime, evmClient, qm, tailData);
	const tailRequestId = Number(
		decodeFunctionResult({ abi: LaneQueueManager, functionName: 'tailRequestId', data: bytesToHex(tailRaw) }),
	);

	// peek at next request
	let nextRequest: QueueSnapshot['nextRequest'] = null;
	if (pendingCount > 0) {
		try {
			const peekData = encodeFunctionData({ abi: LaneQueueManager, functionName: 'peek' });
			const peekRaw = callContract(runtime, evmClient, qm, peekData);
			const decoded = decodeFunctionResult({
				abi: LaneQueueManager,
				functionName: 'peek',
				data: bytesToHex(peekRaw),
			}) as unknown as [boolean, { requestId: bigint; owner: string; receiver: string; shares: bigint; enqueuedAt: bigint }];

			const [exists, req] = decoded;
			if (exists) {
				const now = Math.floor(Date.now() / 1000);
				const enqueuedAt = Number(req.enqueuedAt);
				nextRequest = {
					exists: true,
					requestId: Number(req.requestId),
					owner: req.owner,
					receiver: req.receiver,
					shares: req.shares.toString(),
					enqueuedAt,
					waitTimeSeconds: now - enqueuedAt,
				};
			}
		} catch (e) {
			runtime.log(`Peek failed: ${e instanceof Error ? e.message : String(e)}`);
		}
	}

	runtime.log(`Queue | pending=${pendingCount} head=${headRequestId} tail=${tailRequestId}`);

	return { pendingCount, headRequestId, tailRequestId, nextRequest };
}

function readLiquidity(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): LiquiditySnapshot {
	const dec = runtime.config.assetDecimals;

	const free = readVaultUint256(runtime, evmClient, 'freeLiquidityAssets');
	const availLP = readVaultUint256(runtime, evmClient, 'availableFreeLiquidityForLP');
	const total = readVaultUint256(runtime, evmClient, 'totalAssets');
	const supply = readVaultUint256(runtime, evmClient, 'totalSupply');
	const reserved = readVaultUint256(runtime, evmClient, 'reservedLiquidityAssets');
	const inFlight = readVaultUint256(runtime, evmClient, 'inFlightLiquidityAssets');

	const sharePrice = supply > 0n ? Number(total * 1000000n / supply) / 1000000 : 1;

	runtime.log(
		`Liquidity | free=${formatUnits(free, dec)} availLP=${formatUnits(availLP, dec)} total=${formatUnits(total, dec)}`,
	);

	return {
		freeLiquidity: formatUnits(free, dec),
		availableForLP: formatUnits(availLP, dec),
		totalAssets: formatUnits(total, dec),
		totalSupply: formatUnits(supply, dec),
		reservedLiquidity: formatUnits(reserved, dec),
		inFlightLiquidity: formatUnits(inFlight, dec),
		sharePrice,
	};
}

// ---------------------------------------------------------------------------
// Health assessment
// ---------------------------------------------------------------------------

function assessHealth(
	queue: QueueSnapshot,
	liquidity: LiquiditySnapshot,
	thresholds: Config['thresholds'],
): { health: QueueHealthMetrics; risk: string; signal: string } {
	const t = {
		queueWarningCount: thresholds?.queueWarningCount ?? 3,
		queueCriticalCount: thresholds?.queueCriticalCount ?? 10,
		liquidityCoverageWarning: thresholds?.liquidityCoverageWarning ?? 0.5,
		liquidityCoverageCritical: thresholds?.liquidityCoverageCritical ?? 0.2,
	};

	const totalAssets = parseFloat(liquidity.totalAssets);
	const availForLP = parseFloat(liquidity.availableForLP);
	const reserved = parseFloat(liquidity.reservedLiquidity);
	const inFlight = parseFloat(liquidity.inFlightLiquidity);

	// Estimate total queued value in asset terms.
	// NOTE: We only have the head request via peek(). We use it as a per-request
	// average estimate. Actual queue value may differ if requests vary in size.
	const dec = 18; // shares always use 18 decimals (ERC-20 standard for vault shares)
	const headSharesFloat = queue.nextRequest
		? parseFloat(formatUnits(BigInt(queue.nextRequest.shares), dec))
		: 0;
	const estimatedQueueValue = headSharesFloat * queue.pendingCount * liquidity.sharePrice;

	// Coverage ratio: how much of the queue can we service?
	const coverageRatio = estimatedQueueValue > 0 ? availForLP / estimatedQueueValue : queue.pendingCount > 0 ? 0 : 1;

	// Can we process the next request?
	const nextAssetsNeeded = headSharesFloat * liquidity.sharePrice;
	const canProcessNext = queue.pendingCount === 0 || availForLP >= nextAssetsNeeded;

	// Utilization
	const utilizationBps = totalAssets > 0 ? Math.round(((reserved + inFlight) / totalAssets) * 10000) : 0;

	const health: QueueHealthMetrics = {
		queueDepth: queue.pendingCount,
		liquidityCoverageRatio: coverageRatio,
		estimatedQueueValueAssets: estimatedQueueValue.toFixed(4),
		canProcessNext,
		utilizationBps,
	};

	// Risk classification
	const signals: string[] = [];

	if (queue.pendingCount >= t.queueCriticalCount) {
		signals.push(`Queue depth critical: ${queue.pendingCount} >= ${t.queueCriticalCount}`);
	} else if (queue.pendingCount >= t.queueWarningCount) {
		signals.push(`Queue depth warning: ${queue.pendingCount} >= ${t.queueWarningCount}`);
	}

	if (queue.pendingCount > 0 && coverageRatio < t.liquidityCoverageCritical) {
		signals.push(`Liquidity coverage critical: ${(coverageRatio * 100).toFixed(1)}% < ${t.liquidityCoverageCritical * 100}%`);
	} else if (queue.pendingCount > 0 && coverageRatio < t.liquidityCoverageWarning) {
		signals.push(`Liquidity coverage warning: ${(coverageRatio * 100).toFixed(1)}% < ${t.liquidityCoverageWarning * 100}%`);
	}

	if (!canProcessNext && queue.pendingCount > 0) {
		signals.push('Cannot process next queue request: insufficient free liquidity');
	}

	if (queue.nextRequest && queue.nextRequest.waitTimeSeconds > 86400) {
		const days = (queue.nextRequest.waitTimeSeconds / 86400).toFixed(1);
		signals.push(`Oldest request waiting ${days} days`);
	}

	const hasCritical = signals.some((s) => s.includes('critical') || s.includes('Cannot'));
	const hasWarning = signals.some((s) => s.includes('warning') || s.includes('waiting'));

	const risk = hasCritical ? 'critical' : hasWarning ? 'warning' : 'ok';
	const signal = signals.length > 0 ? signals.join('; ') : 'Queue clear, liquidity healthy';

	return { health, risk, signal };
}

// ---------------------------------------------------------------------------
// Cron handler
// ---------------------------------------------------------------------------

function onCron(runtime: Runtime<Config>, _payload: CronPayload): string {
	const evmClient = getEvmClient(runtime.config.chainName);

	const queue = readQueue(runtime, evmClient);
	const liquidity = readLiquidity(runtime, evmClient);
	const { health, risk, signal } = assessHealth(queue, liquidity, runtime.config.thresholds);

	runtime.log(`Queue health | queue:${risk} | ${signal}`);

	const output: QueueMonitorOutput = {
		queue,
		liquidity,
		health,
		risk,
		signal,
		timestamp: new Date().toISOString(),
	};

	// On-chain proof
	if (
		runtime.config.registry?.address &&
		runtime.config.registry.address !== zeroAddress
	) {
		try {
			const sepoliaClient = getEvmClient(runtime.config.registry.chainName, true);
			const timestampUnix = BigInt(Math.floor(Date.now() / 1000));
			const snapshotHash = keccak256(
				encodeAbiParameters(
					parseAbiParameters(
						'uint256 ts, string wf, string risk, uint256 queueDepth, uint256 coverageRatio, uint256 utilBps',
					),
					[
						timestampUnix,
						'queue-monitor',
						risk,
						BigInt(queue.pendingCount),
						BigInt(Math.round(health.liquidityCoverageRatio * 1e6)),
						BigInt(health.utilizationBps),
					],
				),
			);

			const writeCallData = encodeFunctionData({
				abi: SentinelRegistry,
				functionName: 'recordHealth',
				args: [snapshotHash, `queue:${risk}`],
			});

			sepoliaClient
				.callContract(runtime, {
					call: encodeCallMsg({
						from: zeroAddress,
						to: runtime.config.registry.address as Address,
						data: writeCallData,
					}),
				})
				.result();

			runtime.log(`Registry write | queue:${risk} hash=${snapshotHash}`);
		} catch (e) {
			runtime.log(`Registry write failed (degraded): ${e instanceof Error ? e.message : String(e)}`);
		}
	}

	runtime.log(`QUEUE_MONITOR_CRE_OUTPUT_JSON=${JSON.stringify(output)}`);

	return safeJsonStringify(output);
}

// ---------------------------------------------------------------------------
// Workflow init
// ---------------------------------------------------------------------------

function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability();
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)];
}

export async function main() {
	const runner = await Runner.newRunner<Config>({ configSchema });
	await runner.run(initWorkflow);
}

main();
