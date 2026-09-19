# Current decomposition routing

The [repository README](../../../README.md) describes the current build graph,
frozen inputs, canonical result locations and every manuscript asset producer.
The [mathematical specification](MATHEMATICAL_SPEC.md) defines the scientific
routines and independent accounting checks.

Run `make paper` from the repository root, followed by `make test` for normal validation and
`make test-deep` for exhaustive validation. `make package` and `make replication` are separate explicit exports.
The public four-file cabinet snapshot is an input. Historical repair trees,
intermediate reports and synchronized output mirrors are not dependencies.
