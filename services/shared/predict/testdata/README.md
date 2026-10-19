# Predictor test model

`constant_eta.xgboost` is a synthetic legacy XGBoost binary with 15 input
features, zero base score and one constant zero leaf, with the logistic
objective supported by the current loader. It tests model and encoder loading;
arrival arithmetic uses a separate synthetic raw ensemble. It contains no
trained rider or transit data. The layout follows
the pinned leaves reader in
[xgbin_io.go](https://github.com/dmitryikh/leaves/blob/25d19a787328/internal/xgbin/xgbin_io.go).
