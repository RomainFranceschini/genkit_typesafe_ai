## 0.1.0

- Add reusable TypeSafe AI classifier actions for Genkit.
- Add typed `Noul`, `Choice`, and `Score` response handling through the TypeSafe SDK.
- Add explicit model discovery, Genkit reflection metadata, error mapping, and web support.
- Add named TypeSafe model-router middleware with route-owned model configuration.
- Retain one routing decision across all tool-loop turns in a generation run.
- Expose complete typed route decisions through copied Genkit context.
- Add named TypeSafe Auto Mode middleware to refuse risky calls to explicitly
  guarded Genkit tools while letting the model continue.
