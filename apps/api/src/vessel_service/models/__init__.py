from vessel_service.models.base import Base
from vessel_service.models.app import VesselApp, VesselAppAuditEvent, VesselAppRecord, VesselAppRelease
from vessel_service.models.asset import NoteAsset
from vessel_service.models.directory import NoteDirectory
from vessel_service.models.note import Note
from vessel_service.models.note_agent_run import NoteAgentRun
from vessel_service.models.note_capability import NoteCapability
from vessel_service.models.note_agent_event import NoteAgentEvent
from vessel_service.models.note_version import NoteVersion
from vessel_service.models.proposal import NoteProposal
from vessel_service.models.refresh_session import RefreshSession
from vessel_service.models.space import Space, TeamInvitation, TeamMember
from vessel_service.models.user import User, UserCredential

__all__ = ["Base", "Note", "NoteAgentEvent", "NoteAgentRun", "NoteAsset", "NoteCapability", "NoteDirectory", "NoteProposal", "NoteVersion", "RefreshSession", "Space", "TeamInvitation", "TeamMember", "User", "UserCredential", "VesselApp", "VesselAppAuditEvent", "VesselAppRecord", "VesselAppRelease"]

# Register the independent file domain for migrations and metadata creation.
from vessel_service.files import models as _file_models

from vessel_service.models.registration_email import RegistrationEmailChallenge, RegistrationEmailLimit
