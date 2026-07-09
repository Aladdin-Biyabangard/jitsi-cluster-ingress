// JITSI_CUSTOM_15_USERS — live server (meet.ingress.academy) + recording
// 15 nəfərlik qruplar, 720p, simulcast, Jibri recording

config.defaultLanguage = 'az';

config.channelLastN = 15;
config.resolution = 720;
config.constraints = {
    video: {
        height: { ideal: 720, max: 720, min: 180 }
    }
};

config.enableSimulcast = true;
config.disableSimulcast = false;
config.enableLayerSuspension = true;

config.desktopSharingFrameRate = { min: 5, max: 30 };

// 3+ nəfər üçün server üzərindən (live ilə eyni)
config.p2p = {
    enabled: false
};

config.startAudioMuted = 10;
config.startVideoMuted = 0;
config.startWithAudioMuted = true;
config.startWithVideoMuted = false;
config.enableNoAudioDetection = true;
config.enableNoisyMicDetection = true;

config.enableLobby = true;
config.enableClosePage = false;
config.prejoinPageEnabled = true;
config.prejoinConfig = {
    enabled: true,
    hideExtraJoinButtons: ['no-audio', 'by-phone']
};
config.enableWelcomePage = true;

config.analytics = {};
config.disableThirdPartyRequests = true;

config.toolbarButtons = [
    'microphone', 'camera', 'desktop', 'chat',
    'raisehand', 'participants-pane', 'tileview',
    'fullscreen', 'hangup', 'settings', 'recording'
];

config.filmstrip = {
    disableStageFilmstrip: false
};

// Prosody muc_max_occupants ilə uyğun
config.maxParticipants = 15;

// Server-side recording (Jibri → Bunny)
config.recordingService = {
    enabled: true,
    sharingEnabled: false,
    hideStorageWarning: true
};
config.liveStreamingEnabled = false;
config.fileRecordingsEnabled = true;
config.fileRecordingsServiceEnabled = false;
config.fileRecordingsServiceSharingEnabled = false;
config.hiddenDomain = 'recorder.__DOMAIN__';
