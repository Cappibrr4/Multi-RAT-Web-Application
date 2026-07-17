import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import NavBar from './components/NavBar';
import HomePage from './pages/HomePage';
import SchedulerDashboardPage from './pages/SchedulerDashboardPage';
import TestRunnerPage from './pages/TestRunnerPage';
import MpquicTestRunnerPage from './pages/MpquicTestRunnerPage';
import './App.css';

function App() {
  return (
    <Router>
      <div className="App">
        <NavBar />
        <main>
          <Routes>
            <Route path="/" element={<HomePage />} />
            <Route path="/scheduler" element={<SchedulerDashboardPage />} />
            <Route path="/test" element={<TestRunnerPage />} />
            <Route path="/mpquic" element={<MpquicTestRunnerPage />} />
          </Routes>
        </main>
      </div>
    </Router>
  );
}

export default App;