"""Contracts for Vessel App settings, releases, and audit metadata."""


def test_app_management_schema_has_independent_settings_and_release_versions():
    import vessel_service.models as models

    assert "settings_version" in models.VesselApp.__table__.c
    assert "description" in models.VesselApp.__table__.c
    assert "archived_at" in models.VesselApp.__table__.c
    assert hasattr(models, "VesselAppRelease")
    assert hasattr(models, "VesselAppAuditEvent")
