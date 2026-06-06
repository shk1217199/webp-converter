document.addEventListener('DOMContentLoaded', () => {
    const dropZone = document.getElementById('drop-zone');
    const fileInput = document.getElementById('file-input');
    const fileList = document.getElementById('file-list');
    const fileCount = document.getElementById('file-count');
    const clearBtn = document.getElementById('clear-files-btn');
    const convertBtn = document.getElementById('convert-btn');
    const btnText = convertBtn.querySelector('.btn-text-content');
    const spinner = convertBtn.querySelector('.spinner');
    
    const progressSection = document.getElementById('progress-section');
    const progressBar = document.getElementById('progress-bar');
    const progressPercentage = document.getElementById('progress-percentage');
    const statusLabel = document.getElementById('status-label');
    const logContainer = document.getElementById('log-container');

    let selectedFiles = [];

    // Trigger file selection on click
    dropZone.addEventListener('click', () => fileInput.click());

    // Drag and Drop handlers
    dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('dragover');
    });

    dropZone.addEventListener('dragleave', () => {
        dropZone.classList.remove('dragover');
    });

    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        handleFiles(e.dataTransfer.files);
    });

    fileInput.addEventListener('change', (e) => {
        handleFiles(e.target.files);
    });

    function handleFiles(files) {
        if (files.length === 0) return;
        
        Array.from(files).forEach(file => {
            // Simple duplicate check
            if (!selectedFiles.find(f => f.name === file.name)) {
                selectedFiles.push(file);
            }
        });
        
        updateFileUI();
    }

    function removeFile(index) {
        selectedFiles.splice(index, 1);
        updateFileUI();
    }

    clearBtn.addEventListener('click', () => {
        selectedFiles = [];
        updateFileUI();
    });

    function updateFileUI() {
        fileCount.textContent = selectedFiles.length;
        
        if (selectedFiles.length === 0) {
            fileList.innerHTML = '<div class="empty-state">No files selected</div>';
            clearBtn.style.display = 'none';
            convertBtn.disabled = true;
            return;
        }

        clearBtn.style.display = 'block';
        convertBtn.disabled = false;
        fileList.innerHTML = '';

        selectedFiles.forEach((file, index) => {
            const item = document.createElement('div');
            item.className = 'file-item';
            
            // Icon based on type
            const isVideo = file.name.match(/\.(mp4|mov|avi|mkv|webm)$/i);
            const iconSvg = isVideo ? 
                `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18"></rect><line x1="7" y1="2" x2="7" y2="22"></line><line x1="17" y1="2" x2="17" y2="22"></line><line x1="2" y1="12" x2="22" y2="12"></line><line x1="2" y1="7" x2="7" y2="7"></line><line x1="2" y1="17" x2="7" y2="17"></line><line x1="17" y1="17" x2="22" y2="17"></line><line x1="17" y1="7" x2="22" y2="7"></line></svg>` : 
                `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line><polyline points="10 9 9 9 8 9"></polyline></svg>`;

            // Icon wrapper
            const icon = document.createElement('div');
            icon.className = 'file-icon';
            icon.innerHTML = iconSvg;
            
            // Name
            const name = document.createElement('div');
            name.className = 'file-name';
            name.textContent = file.name;

            // Remove Btn
            const remove = document.createElement('button');
            remove.className = 'file-remove';
            remove.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>`;
            remove.onclick = (e) => {
                e.stopPropagation();
                removeFile(index);
            };

            item.appendChild(icon);
            item.appendChild(name);
            item.appendChild(remove);
            fileList.appendChild(item);
        });
    }

    // Mock Conversion Process to simulate the UI interactivity
    convertBtn.addEventListener('click', async () => {
        if (selectedFiles.length === 0) return;

        // Update UI State
        convertBtn.disabled = true;
        btnText.style.display = 'none';
        spinner.style.display = 'block';
        
        progressSection.style.display = 'block';
        logContainer.innerHTML = '';
        progressBar.style.width = '0%';
        
        let successCount = 0;
        
        const addLog = (msg, type = 'normal') => {
            const entry = document.createElement('div');
            entry.className = `log-entry ${type}`;
            const time = new Date().toLocaleTimeString('en-US', { hour12: false });
            entry.textContent = `[${time}] ${msg}`;
            logContainer.appendChild(entry);
            logContainer.scrollTop = logContainer.scrollHeight; // Auto-scroll
        };

        addLog(`Initializing conversion engine...`);
        addLog(`Starting conversion of ${selectedFiles.length} file(s)...`);

        for (let i = 0; i < selectedFiles.length; i++) {
            const file = selectedFiles[i];
            statusLabel.textContent = `Processing: ${file.name}`;
            
            // Simulate variable processing time based on file index
            await new Promise(resolve => setTimeout(resolve, 800 + Math.random() * 1000));
            
            // Update progress bar
            const progress = Math.round(((i + 1) / selectedFiles.length) * 100);
            progressBar.style.width = `${progress}%`;
            progressPercentage.textContent = `${progress}%`;
            
            // 90% mock success rate
            if (Math.random() > 0.1 || selectedFiles.length === 1) {
                successCount++;
                const outName = file.name.substring(0, file.name.lastIndexOf('.')) || file.name;
                addLog(`SUCCESS: ${file.name} -> ./converted/${outName}.webp`, 'success');
            } else {
                addLog(`ERROR: ${file.name} - Format unsupported or corrupted.`, 'error');
            }
        }

        statusLabel.textContent = `Completed: ${successCount} successful, ${selectedFiles.length - successCount} failed.`;
        addLog(`All tasks completed.`);
        
        // Restore UI Button State
        convertBtn.disabled = false;
        btnText.style.display = 'block';
        btnText.textContent = 'Convert More Files';
        spinner.style.display = 'none';
    });
});
