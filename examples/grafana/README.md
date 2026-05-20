# Grafana Dashboard

This directory contains a starter Grafana dashboard for the built-in Prometheus metrics exporter.

## Import

1. In Grafana, open **Dashboards**.
2. Choose **New** > **Import**.
3. Upload `activejob_temporal_dashboard.json`.
4. Select your Prometheus data source.

The dashboard expects workers to expose `GET /metrics` and Prometheus to scrape those targets. Scrape Rails or other enqueueing processes too if you want enqueue and payload-size panels to show data.
